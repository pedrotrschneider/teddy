import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/ted/teddy_updates.dart';
import 'package:plezy/ted/teddy_update_installer.dart';

Map<String, dynamic> release(String version, {bool draft = false}) => {
  'tag_name': 'v$version',
  'draft': draft,
  'prerelease': version.contains('-rc'),
  'assets': [
    {
      'name': 'Teddy-$version-macos-universal.zip',
      'state': 'uploaded',
      'browser_download_url':
          'https://github.com/pedrotrschneider/teddy/releases/download/v$version/Teddy-$version-macos-universal.zip',
    },
  ],
};
void main() {
  test('channel ordering handles final releases, rc10, drafts, compatibility and no downgrades', () {
    final items = [
      release('0.2.0-rc2'),
      release('0.2.0-rc10'),
      release('0.1.9'),
      release('1.0.0'),
      release('0.3.0', draft: true),
    ];
    expect(TeddyUpdates.select(items, '0.1.8', false)?.version.toString(), '0.1.9');
    expect(TeddyUpdates.select(items, '0.1.8', true)?.version.toString(), '0.2.0-rc10');
    expect(TeddyUpdates.select([...items, release('0.2.0')], '0.2.0-rc10', true)?.version.toString(), '0.2.0');
    expect(TeddyUpdates.select(items, '0.2.0', true), isNull);
    expect(TeddyUpdates.select(items, '0.1.0-dev', true), isNull);
  });
  test('assets must come from the expected repository and version', () {
    final wrong = release('0.1.9');
    (wrong['assets'] as List).single['browser_download_url'] = 'https://evil.example/app.zip';
    expect(TeddyUpdates.select([wrong], '0.1.8', false), isNull);
  });
  test('platform package and exact checksum matching', () {
    expect(teddyUpdateAssetSuffix('linux', Abi.linuxArm64), 'linux-arm64.tar.gz');
    expect(teddyUpdateAssetSuffix('windows', Abi.windowsArm64), isNull);
    final hash = 'a' * 64;
    expect(parseUpdateChecksum('$hash  Teddy.zip\n', 'Teddy.zip'), hash);
    expect(() => parseUpdateChecksum('$hash  Other.zip', 'Teddy.zip'), throwsA(isA<TeddyUpdateFailure>()));
    expect(
      () => parseUpdateChecksum('$hash  Teddy.zip\n$hash  Teddy.zip', 'Teddy.zip'),
      throwsA(isA<TeddyUpdateFailure>()),
    );
  });
  test('portable install refuses folders containing personal files', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-bundle-test');
    addTearDown(() => dir.delete(recursive: true));
    await expectLater(validateTeddyBundle(dir.path), throwsA(isA<TeddyUpdateFailure>()));
    await File(
      p.join(dir.path, 'teddy-release.json'),
    ).writeAsString('{"product":"Teddy","entries":["teddy-release.json","Teddy.exe"]}');
    await File(p.join(dir.path, 'Teddy.exe')).writeAsString('test');
    await validateTeddyBundle(dir.path);
    await File(p.join(dir.path, 'personal.txt')).writeAsString('keep');
    await expectLater(validateTeddyBundle(dir.path), throwsA(isA<TeddyUpdateFailure>()));
    expect(await File(p.join(dir.path, 'personal.txt')).readAsString(), 'keep');
  });
  test('unsafe archive paths fail without writing outside staging', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-archive-test');
    addTearDown(() => dir.delete(recursive: true));
    final archive = Archive()..add(ArchiveFile('../outside', 1, [1]));
    final file = File(p.join(dir.path, 'bad.zip'));
    await file.writeAsBytes(ZipEncoder().encode(archive));
    await expectLater(
      extractTeddyUpdate(file.path, p.join(dir.path, 'new'), 'windows'),
      throwsA(isA<TeddyUpdateFailure>()),
    );
    expect(File(p.join(dir.path, 'outside')).existsSync(), false);
  });
  test('cancelled installer leaves the live bundle unchanged', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-cancel-test');
    addTearDown(() => dir.delete(recursive: true));
    final target = await Directory(p.join(dir.path, 'Teddy')).create();
    await File(p.join(target.path, 'original')).writeAsString('keep');
    final script = File(p.join(dir.path, 'install.sh'));
    await script.writeAsString(teddyUnixUpdateScript);
    final cancel = File(p.join(dir.path, 'cancel'));
    await cancel.writeAsString('cancel');
    final result = await Process.run('/bin/sh', [
      script.path,
      pid.toString(),
      target.path,
      p.join(dir.path, 'new'),
      p.join(dir.path, 'previous'),
      cancel.path,
      p.join(dir.path, 'log'),
      'linux',
    ], workingDirectory: dir.path);
    expect(result.exitCode, 0);
    expect(await File(p.join(target.path, 'original')).readAsString(), 'keep');
  }, skip: Platform.isWindows);
  for (final missingPayload in [false, true]) {
    test(
      'desktop helper waits for exit and ${missingPayload ? 'restores on replacement failure' : 'replaces and relaunches'}',
      () async {
        final dir = await Directory.systemTemp.createTemp("teddy update ' test");
        addTearDown(() => dir.delete(recursive: true));
        final target = await Directory(p.join(dir.path, 'Teddy old')).create();
        await File(p.join(target.path, 'original')).writeAsString('original');
        final stage = await Directory(p.join(dir.path, 'stage')).create();
        final payload = Directory(p.join(stage.path, 'new'));
        if (!missingPayload) {
          await payload.create();
          final binary = File(p.join(payload.path, 'Teddy'));
          await binary.writeAsString('#!/bin/sh\ntouch "${dir.path}/started"\n');
          await Process.run('/bin/chmod', ['+x', binary.path]);
        }
        final script = File(p.join(stage.path, 'install.sh'));
        await script.writeAsString(teddyUnixUpdateScript);
        final parent = await Process.start('/bin/sleep', ['30']);
        addTearDown(() => parent.kill());
        final helper = await Process.start('/bin/sh', [
          script.path,
          parent.pid.toString(),
          target.path,
          payload.path,
          p.join(stage.path, 'previous'),
          p.join(stage.path, 'cancel'),
          p.join(stage.path, 'log'),
          'linux',
        ], workingDirectory: stage.path);
        for (var i = 0; i < 50 && !File(p.join(stage.path, 'ready')).existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(File(p.join(target.path, 'original')).existsSync(), true);
        parent.kill();
        await parent.exitCode;
        final code = await helper.exitCode.timeout(const Duration(seconds: 10));
        expect(code, missingPayload ? 1 : 0);
        expect(File(p.join(target.path, 'original')).existsSync(), missingPayload);
        if (!missingPayload) {
          for (var i = 0; i < 50 && !File(p.join(dir.path, 'started')).existsSync(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(File(p.join(dir.path, 'started')).existsSync(), true);
          expect(File(p.join(stage.path, 'previous', 'original')).existsSync(), true);
        }
      },
      skip: Platform.isWindows,
    );
  }
}
