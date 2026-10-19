import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'teddy_update_cleanup.dart';
import 'teddy_updates.dart';

class TeddyUpdateFailure implements Exception {
  final String message;
  const TeddyUpdateFailure(this.message);
  @override
  String toString() => message;
}

String? teddyUpdateAssetSuffix(String os, Abi abi) => switch (os) {
  'macos' => 'macos-universal.zip',
  'android' => 'android-universal.apk',
  'windows' when abi == Abi.windowsX64 => 'windows-x64.zip',
  'linux' when abi == Abi.linuxX64 => 'linux-x64.tar.gz',
  'linux' when abi == Abi.linuxArm64 => 'linux-arm64.tar.gz',
  _ => null,
};

String parseUpdateChecksum(String manifest, String asset) {
  final matches = manifest
      .split('\n')
      .map((line) => RegExp(r'^([0-9a-fA-F]{64})  (.+)$').firstMatch(line.trim()))
      .where((m) => m != null && m[2] == asset)
      .toList();
  if (matches.length != 1) throw const TeddyUpdateFailure('The release checksum is missing or ambiguous.');
  return matches.single![1]!.toLowerCase();
}

/// Helpers never replace a running bundle. The previous bundle stays alongside
/// staging for recovery; account/download data lives outside both bundles.
class TeddyPreparedUpdate {
  final Directory stage;
  final String? target, payload;
  final File? apk;
  final TeddyUpdateStage? ownership;
  const TeddyPreparedUpdate(this.stage, {this.target, this.payload, this.apk, this.ownership});
  Future<void> cancel() => File(p.join(stage.path, 'cancel')).writeAsString('cancel');
  Future<void> discard() async {
    try {
      await cancel();
    } finally {
      await ownership?.close();
    }
    await stage.delete(recursive: true);
  }

  Future<void> start() async {
    if (apk != null) {
      // A fresh timestamp gives the system installer a full grace period,
      // including when the permission prompt delayed the handoff.
      await apk!.setLastModified(DateTime.now());
      final opened = await const MethodChannel('teddy/updates').invokeMethod<bool>('install', {'path': apk!.path});
      if (opened != true) {
        throw const TeddyUpdateFailure('Allow Teddy to install updates in Android settings, then press Update again.');
      }
      await ownership?.close();
      return;
    }
    final script = File(p.join(stage.path, Platform.isWindows ? 'install.ps1' : 'install.sh'));
    await script.writeAsString(Platform.isWindows ? teddyWindowsUpdateScript : teddyUnixUpdateScript, flush: true);
    final arguments = [
      pid.toString(),
      target!,
      payload!,
      p.join(stage.path, 'previous'),
      p.join(stage.path, 'cancel'),
      p.join(stage.path, 'install.log'),
      Platform.operatingSystem,
    ];
    if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'];
      if (root == null) throw const TeddyUpdateFailure('Windows installation tools are unavailable.');
      await Process.start(
        p.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path, ...arguments],
        mode: ProcessStartMode.detached,
        workingDirectory: stage.path,
      );
    } else {
      await Process.start(
        '/bin/sh',
        [script.path, ...arguments],
        mode: ProcessStartMode.detached,
        workingDirectory: stage.path,
      );
    }
    // Do not close Teddy unless the detached helper actually started.
    for (var i = 0; i < 50; i++) {
      if (await File(p.join(stage.path, 'ready')).exists()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await cancel();
    throw const TeddyUpdateFailure('The installer could not start. Teddy has not been replaced.');
  }
}

class TeddyUpdateInstaller {
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  bool _cancelled = false;
  void cancel() {
    _cancelled = true;
    _client.close(force: true);
  }

  void _check() {
    if (_cancelled) throw const TeddyUpdateFailure('Update cancelled.');
  }

  Future<HttpClientResponse> _get(Uri uri) async {
    for (var redirect = 0; redirect < 6; redirect++) {
      _check();
      if (uri.scheme != 'https' || !(uri.host == 'github.com' || uri.host.endsWith('.githubusercontent.com'))) {
        throw const TeddyUpdateFailure('Untrusted update download address.');
      }
      final request = await _client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) break;
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw const TeddyUpdateFailure('The update could not be downloaded. Please try again.');
      }
      return response;
    }
    throw const TeddyUpdateFailure('Too many update download redirects.');
  }

  Future<TeddyPreparedUpdate> prepare(TeddyUpdate update, void Function(String, double?) progress) async {
    final suffix = teddyUpdateAssetSuffix(Platform.operatingSystem, Abi.current());
    if (suffix == null) throw const TeddyUpdateFailure('This platform has no supported update package.');
    final name = 'Teddy-${update.version}-$suffix';
    final asset = update.assets[name];
    final checksum = update.assets[name.replaceFirst(RegExp(r'\.(zip|tar\.gz|apk)$'), '.sha256')];
    if (asset == null || checksum == null) {
      throw const TeddyUpdateFailure('This release is missing its platform package or checksum.');
    }
    final location = await teddyUpdateLocation();
    if (location == null) {
      throw const TeddyUpdateFailure('Install an official Teddy release before using in-app updates.');
    }
    final target = location.target;
    if (target != null && !Platform.isMacOS) await validateTeddyBundle(target);
    late final TeddyUpdateStage ownership;
    try {
      if (Platform.isAndroid) await location.parent.create(recursive: true);
      ownership = await TeddyUpdateStage.create(location.parent, name);
    } catch (_) {
      throw const TeddyUpdateFailure(
        'Teddy’s installation folder is not writable. Move it to a folder you own before updating.',
      );
    }
    final stage = ownership.directory;
    try {
      progress('Verifying release information…', null);
      final response = await _get(checksum);
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 16384) throw const TeddyUpdateFailure('Invalid release checksum file.');
      }
      final expected = parseUpdateChecksum(String.fromCharCodes(bytes), name);
      final archive = File(p.join(stage.path, name));
      final download = await _get(asset);
      var received = 0;
      final total = download.contentLength;
      final sink = archive.openWrite();
      try {
        await for (final chunk in download.timeout(const Duration(seconds: 30))) {
          _check();
          received += chunk.length;
          if (received > 4 * 1024 * 1024 * 1024) {
            throw const TeddyUpdateFailure('The update package is unexpectedly large.');
          }
          sink.add(chunk);
          if (received ~/ (16 * 1024 * 1024) != (received - chunk.length) ~/ (16 * 1024 * 1024)) await sink.flush();
          progress('Downloading update…', total > 0 ? received / total : null);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (total >= 0 && received != total) throw const TeddyUpdateFailure('The update download was incomplete.');
      progress('Checking download…', null);
      final actual = (await sha256.bind(archive.openRead()).first).toString();
      if (actual != expected) throw const TeddyUpdateFailure('Update checksum mismatch. Nothing was installed.');
      _check();
      if (Platform.isAndroid) return TeddyPreparedUpdate(stage, apk: archive, ownership: ownership);
      progress('Preparing installation…', null);
      final output = p.join(stage.path, 'new');
      await Isolate.run(() => extractTeddyUpdate(archive.path, output, Platform.operatingSystem));
      _check();
      final payload = Platform.isMacOS
          ? p.join(output, 'Teddy.app')
          : Platform.isLinux
          ? p.join(output, 'Teddy')
          : output;
      final binary = Platform.isMacOS
          ? p.join(payload, 'Contents', 'MacOS', 'Teddy')
          : p.join(payload, Platform.isWindows ? 'Teddy.exe' : 'Teddy');
      if (!await File(binary).exists()) throw const TeddyUpdateFailure('The update package does not contain Teddy.');
      if (!Platform.isMacOS) await validateTeddyBundle(payload);
      if (Platform.isMacOS) {
        final verified = await Process.run('/usr/bin/codesign', ['--verify', '--deep', '--strict', payload]);
        if (verified.exitCode != 0) {
          throw const TeddyUpdateFailure('The downloaded application failed signature validation.');
        }
      }
      return TeddyPreparedUpdate(stage, target: target, payload: payload, ownership: ownership);
    } catch (_) {
      await ownership.close();
      await stage.delete(recursive: true);
      rethrow;
    } finally {
      _client.close(force: true);
    }
  }
}

Future<void> validateTeddyBundle(String directory) async {
  final marker = File(p.join(directory, 'teddy-release.json'));
  if (!await marker.exists() || await marker.length() > 65536) {
    throw const TeddyUpdateFailure(
      'This is not an updatable portable Teddy installation. Install an official release in its own folder.',
    );
  }
  final data = jsonDecode(await marker.readAsString());
  if (data is! Map || data['product'] != 'Teddy' || data['entries'] is! List) {
    throw const TeddyUpdateFailure('Invalid Teddy installation manifest.');
  }
  final entries = data['entries'] as List;
  await for (final entry in Directory(directory).list(followLinks: false)) {
    if (!entries.contains(p.basename(entry.path)) && p.basename(entry.path) != '.DS_Store') {
      throw const TeddyUpdateFailure(
        'The installation folder contains extra files. Move personal files out of it before updating.',
      );
    }
  }
}

Future<void> extractTeddyUpdate(String file, String output, String os) async {
  String input = file;
  if (os == 'linux') {
    input = '$file.tar';
    final sink = File(input).openWrite();
    var size = 0;
    try {
      await for (final chunk in File(file).openRead().transform(gzip.decoder)) {
        size += chunk.length;
        if (size > 8 * 1024 * 1024 * 1024) throw const TeddyUpdateFailure('Update expands beyond its size limit.');
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
  final stream = InputFileStream(input);
  try {
    final archive = os == 'linux' ? TarDecoder().decodeStream(stream) : ZipDecoder().decodeStream(stream);
    var size = 0;
    for (final entry in archive) {
      final name = entry.name.replaceAll('\\', '/');
      size += entry.size;
      if (size > 8 * 1024 * 1024 * 1024 ||
          p.posix.isAbsolute(name) ||
          name.split('/').contains('..') ||
          name.contains(':')) {
        throw const TeddyUpdateFailure('Unsafe update archive.');
      }
      if (entry.isSymbolicLink) {
        final link = entry.symbolicLink!.replaceAll('\\', '/');
        final resolved = p.posix.normalize(p.posix.join(p.posix.dirname(name), link));
        if (p.posix.isAbsolute(link) || resolved == '..' || resolved.startsWith('../')) {
          throw const TeddyUpdateFailure('Unsafe update archive link.');
        }
      }
    }
    await Directory(output).create(recursive: true);
    if (os == 'macos') {
      final result = await Process.run('/usr/bin/ditto', ['-x', '-k', file, output]);
      if (result.exitCode != 0) throw const TeddyUpdateFailure('Could not unpack the update.');
    } else if (os == 'linux') {
      final result = await Process.run('/bin/tar', ['-xf', input, '-C', output, '--no-same-owner']);
      if (result.exitCode != 0) throw const TeddyUpdateFailure('Could not unpack the update.');
    } else {
      for (final entry in archive) {
        final destination = p.join(output, entry.name);
        if (entry.isSymbolicLink) throw const TeddyUpdateFailure('Unexpected link in Windows update.');
        if (entry.isDirectory) {
          await Directory(destination).create(recursive: true);
          continue;
        }
        await File(destination).parent.create(recursive: true);
        final sink = OutputFileStream(destination);
        try {
          entry.writeContent(sink);
        } finally {
          await sink.close();
        }
        if (await File(destination).length() != entry.size) {
          throw const TeddyUpdateFailure('Incomplete update extraction.');
        }
      }
    }
  } finally {
    await stream.close();
    if (input != file) await File(input).delete();
  }
}

const teddyUnixUpdateScript = r'''#!/bin/sh
set -eu
parent_pid=$1; target=$2; payload=$3; backup=$4; cancel=$5; log=$6; platform=$7
exec >>"$log" 2>&1
touch ready
count=0
while kill -0 "$parent_pid" 2>/dev/null; do
  [ ! -e "$cancel" ] || exit 0
  count=$((count+1)); [ "$count" -lt 180 ] || exit 1
  sleep 1
done
[ ! -e "$cancel" ] || exit 0
mv "$target" "$backup"
if ! mv "$payload" "$target"; then mv "$backup" "$target"; exit 1; fi
if [ "$platform" = macos ]; then
  if ! /usr/bin/open "$target"; then mv "$target" "$payload"; mv "$backup" "$target"; /usr/bin/open "$target"; exit 1; fi
else
  "$target/Teddy" >/dev/null 2>&1 &
fi
''';

const teddyWindowsUpdateScript = r'''
param([int]$ParentId,[string]$Target,[string]$Payload,[string]$Backup,[string]$Cancel,[string]$Log,[string]$Platform)
$ErrorActionPreference='Stop'
try {
  Set-Content -LiteralPath (Join-Path $PSScriptRoot 'ready') -Value 'ready'
  for($i=0;$i -lt 180;$i++) {
    if(Test-Path -LiteralPath $Cancel){exit 0}
    if(-not (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)){break}
    Start-Sleep -Seconds 1
  }
  if((Test-Path -LiteralPath $Cancel) -or (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)){exit 1}
  Move-Item -LiteralPath $Target -Destination $Backup
  try {Move-Item -LiteralPath $Payload -Destination $Target}
  catch {Move-Item -LiteralPath $Backup -Destination $Target;throw}
  try {Start-Process -FilePath (Join-Path $Target 'Teddy.exe') -WorkingDirectory $Target}
  catch {Move-Item -LiteralPath $Target -Destination $Payload;Move-Item -LiteralPath $Backup -Destination $Target;throw}
} catch {$_ | Out-File -LiteralPath $Log;exit 1}
''';
