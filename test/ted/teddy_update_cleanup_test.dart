import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/ted/teddy_update_cleanup.dart';
import 'package:plezy/ted/teddy_update_installer.dart';

const _apk = 'Teddy-0.2.1-android-universal.apk';
const _packages = [
  _apk,
  'Teddy-0.2.1-rc2-macos-universal.zip',
  'Teddy-0.2.1-windows-x64.zip',
  'Teddy-0.2.1-linux-x64.tar.gz',
  'Teddy-0.2.1-linux-arm64.tar.gz',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DateTime now;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('teddy-cleanup-test-');
    now = DateTime.now().add(const Duration(days: 2));
  });
  tearDown(() async => root.delete(recursive: true));

  Future<TeddyUpdateStage> stage(String archive) async {
    final owned = await TeddyUpdateStage.create(root, archive);
    await File(p.join(owned.directory.path, archive)).writeAsString('download');
    return owned;
  }

  test('all platform packages expire after 24h; rollback apps/logs, recent and foreign files survive', () async {
    for (final archive in _packages) {
      final owned = await stage(archive);
      final dir = owned.directory;
      await Directory(p.join(dir.path, 'previous')).create();
      await File(p.join(dir.path, 'previous', 'original')).writeAsString('rollback');
      await File(p.join(dir.path, 'install.log')).writeAsString('diagnostics');
      // A partial Linux decompression is also an owned package.
      if (archive.endsWith('.tar.gz')) await File(p.join(dir.path, '$archive.tar')).writeAsString('tar');
      await owned.close();
    }
    final recent = await stage(_apk);
    await File(p.join(recent.directory.path, _apk)).setLastModified(now.subtract(const Duration(hours: 23)));
    await recent.close();
    final legacy = await Directory(p.join(root.path, '.teddy-update-legacy')).create();
    await File(p.join(legacy.path, _apk)).writeAsString('old APK');
    await File(p.join(legacy.path, 'personal.txt')).writeAsString('keep');
    final foreign = await Directory(p.join(root.path, 'personal')).create();
    await File(p.join(foreign.path, _apk)).writeAsString('keep');
    final unknown = await Directory(p.join(root.path, '.teddy-update-foreign')).create();
    await File(p.join(unknown.path, 'archive.zip')).writeAsString('keep');

    await cleanupTeddyUpdates(root: root, now: now);
    expect(await File(p.join(recent.directory.path, _apk)).exists(), true);
    expect(await File(p.join(legacy.path, _apk)).exists(), false);
    expect(await File(p.join(legacy.path, 'personal.txt')).readAsString(), 'keep');
    expect(await File(p.join(foreign.path, _apk)).exists(), true);
    expect(await File(p.join(unknown.path, 'archive.zip')).exists(), true);
    final backups = await root
        .list()
        .where((e) => e is Directory && File(p.join(e.path, 'install.log')).existsSync())
        .toList();
    expect(backups.length, _packages.length);
    for (final backup in backups) {
      expect(await File(p.join(backup.path, 'previous', 'original')).readAsString(), 'rollback');
      expect(await File(p.join(backup.path, 'install.log')).readAsString(), 'diagnostics');
      final children = await Directory(backup.path).list().toList();
      expect(
        children.whereType<File>().where((e) => _packages.any((name) => p.basename(e.path).startsWith(name))),
        isEmpty,
      );
    }
    // Once the grace expires, Android's whole empty owned stage is removed.
    await cleanupTeddyUpdates(root: root, now: now.add(const Duration(hours: 2)));
    expect(await recent.directory.exists(), false);
  });

  test(
    'abandoned owned payload is removed; pending helpers, legacy payloads, links and running bundles survive',
    () async {
      final abandoned = await stage(_packages[1]);
      final outside = await Directory(p.join(root.path, 'personal-data')).create();
      await File(p.join(outside.path, 'keep')).writeAsString('personal');
      await Directory(p.join(abandoned.directory.path, 'new')).create();
      await File(p.join(abandoned.directory.path, 'new', 'partial')).writeAsString('partial');
      if (!Platform.isWindows) {
        await Link(p.join(abandoned.directory.path, 'new', 'link')).create(outside.path);
        await Link(p.join(root.path, '.teddy-update-linked')).create(outside.path);
      }
      await abandoned.close();
      final pending = await stage(_packages[1]);
      await Directory(p.join(pending.directory.path, 'new')).create();
      await File(p.join(pending.directory.path, 'new', 'recovery')).writeAsString('keep');
      await File(p.join(pending.directory.path, 'ready')).writeAsString('ready');
      await pending.close();
      final legacy = await Directory(p.join(root.path, '.teddy-update-no-owner')).create();
      await File(p.join(legacy.path, _apk)).writeAsString('old download');
      await Directory(p.join(legacy.path, 'new')).create();
      await File(p.join(legacy.path, 'new', 'personal')).writeAsString('keep');
      final running = await stage(_packages[2]);
      final executable = await File(p.join(running.directory.path, 'Teddy.exe')).writeAsString('running');
      await running.close();
      final linked = await stage(_apk);
      if (!Platform.isWindows) {
        await File(p.join(linked.directory.path, _apk)).delete();
        await Link(p.join(linked.directory.path, _apk)).create(p.join(outside.path, 'keep'));
      }
      await linked.close();

      await cleanupTeddyUpdates(root: root, now: now, executable: executable.path);
      expect(await abandoned.directory.exists(), false);
      expect(await File(p.join(outside.path, 'keep')).readAsString(), 'personal');
      expect(await File(p.join(pending.directory.path, _packages[1])).exists(), false);
      expect(await File(p.join(pending.directory.path, 'new', 'recovery')).readAsString(), 'keep');
      expect(await File(p.join(legacy.path, _apk)).exists(), false);
      expect(await File(p.join(legacy.path, 'new', 'personal')).readAsString(), 'keep');
      expect(await executable.exists(), true);
      expect(await File(p.join(running.directory.path, _packages[2])).exists(), true);
      if (!Platform.isWindows) expect(await Link(p.join(linked.directory.path, _apk)).exists(), true);
    },
  );

  test('prepared update remains protected until discard or abandonment releases ownership', () async {
    final active = await stage(_apk);
    final prepared = TeddyPreparedUpdate(
      active.directory,
      apk: File(p.join(active.directory.path, _apk)),
      ownership: active,
    );
    await cleanupTeddyUpdates(root: root, now: now);
    // Opening another POSIX handle would release the process's original lock
    // when closed; the in-process fence avoids that trap too.
    await cleanupTeddyUpdates(root: root, now: now);
    expect(await prepared.apk!.exists(), true);
    await prepared.discard();
    expect(await active.directory.exists(), false);
    final abandoned = await stage(_apk);
    await abandoned.close();
    await cleanupTeddyUpdates(root: root, now: now);
    expect(await abandoned.directory.exists(), false);
  });

  test('Android permission retry retains the APK; installer handoff releases it with a fresh grace period', () async {
    final active = await stage(_apk);
    final apk = File(p.join(active.directory.path, _apk));
    await apk.setLastModified(DateTime.now().subtract(const Duration(days: 2)));
    final prepared = TeddyPreparedUpdate(active.directory, apk: apk, ownership: active);
    var allowed = false;
    const channel = MethodChannel('teddy/updates');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'install');
      expect(call.arguments, {'path': apk.path});
      return allowed;
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await active.close();
    });
    await expectLater(prepared.start(), throwsA(isA<TeddyUpdateFailure>()));
    await cleanupTeddyUpdates(root: root, now: now);
    expect(await apk.exists(), true, reason: 'Permission retry still owns its prepared APK');
    allowed = true;
    await prepared.start();
    // A new handle can acquire the stage only once handoff released ownership.
    final released = await TeddyUpdateStage.acquire(active.directory);
    expect(released, isNotNull);
    await released!.close();
    await cleanupTeddyUpdates(root: root);
    expect(await apk.exists(), true, reason: 'Android needs its entire fresh grace period');
    await cleanupTeddyUpdates(root: root, now: DateTime.now().add(const Duration(hours: 25)));
    expect(await active.directory.exists(), false);
  });

  test('another process holding the stage lock prevents removal until it exits', () async {
    final active = await stage(_apk);
    await active.close();
    final script = await File(p.join(root.path, 'lock.dart')).writeAsString(r'''
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = await File(args.single).open(mode: FileMode.append);
  await file.lock(FileLock.exclusive, 0, 1);
  stdout.writeln('locked');
  await stdin.first;
  await file.close();
}
''');
    final child = await Process.start(Platform.isWindows ? 'dart.exe' : 'dart', [
      script.path,
      p.join(active.directory.path, 'update.lock'),
    ]);
    addTearDown(() => child.kill());
    final errors = child.stderr.transform(utf8.decoder).join();
    expect(await child.stdout.transform(utf8.decoder).transform(const LineSplitter()).first, 'locked');
    await cleanupTeddyUpdates(root: root, now: now);
    expect(await File(p.join(active.directory.path, _apk)).exists(), true);
    child.stdin.writeln('release');
    await child.stdin.close();
    expect(await child.exitCode, 0, reason: await errors);
    await cleanupTeddyUpdates(root: root, now: now);
    expect(await active.directory.exists(), false);
  });

  test('startup, periodic and resume sweeps are single-flight, retry failures and stop on disposal', () {
    fakeAsync((clock) {
      var calls = 0;
      Completer<void>? held;
      final cleanup = TeddyUpdateCleanup(
        now: () => now.add(clock.elapsed),
        sweep: () async {
          calls++;
          if (calls == 1) await (held = Completer<void>()).future;
          if (calls == 2) throw const FileSystemException('test failure');
        },
      );
      cleanup.start();
      cleanup.start();
      clock.flushMicrotasks();
      expect(calls, 1);
      clock.elapse(const Duration(hours: 12));
      cleanup.check();
      expect(calls, 1);
      held!.complete();
      clock.flushMicrotasks();
      cleanup.check(); // Resume after a long suspension; due immediately.
      clock.flushMicrotasks();
      expect(calls, 2);
      cleanup.check();
      clock.elapse(teddyUpdateCleanupInterval);
      expect(calls, 3);
      cleanup.stop();
      clock.elapse(const Duration(days: 2));
      cleanup.check();
      expect(calls, 3);
      expect(clock.periodicTimerCount, 0);
    });
  });
}
