import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../utils/app_logger.dart';

const teddyUpdateRetention = Duration(hours: 24);
const teddyUpdateCleanupInterval = Duration(hours: 6);
const _ownerFile = 'teddy-update.json';
const _lockFile = 'update.lock';
final _packageName = RegExp(
  r'^Teddy-\d+\.\d+\.\d+(?:-rc\d+)?-(?:android-universal\.apk|macos-universal\.zip|windows-x64\.zip|linux-(?:x64|arm64)\.tar\.gz)(?:\.tar)?$',
);

/// Both preparation and cleanup resolve the same platform-specific staging root.
Future<({Directory parent, String? target})?> teddyUpdateLocation() async {
  if (Platform.isAndroid) {
    return (parent: Directory(p.join((await getTemporaryDirectory()).path, 'teddy-updates')), target: null);
  }
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) return null;
  final executable = await File(Platform.resolvedExecutable).resolveSymbolicLinks();
  final target = Platform.isMacOS ? p.dirname(p.dirname(p.dirname(executable))) : p.dirname(executable);
  final valid = Platform.isMacOS
      ? p.basename(target).endsWith('.app') && p.basename(executable) == 'Teddy'
      : await File(p.join(target, Platform.isWindows ? 'Teddy.exe' : 'Teddy')).exists();
  if (!valid || p.dirname(target) == target) return null;
  return (parent: Directory(p.dirname(target)), target: target);
}

/// A held file lock fences other processes; the set also fences this process
/// because POSIX file locks are process-scoped, rather than handle-scoped.
class TeddyUpdateStage {
  static final _held = <String>{};
  final Directory directory;
  final RandomAccessFile _lock;
  Future<void>? _closing;
  TeddyUpdateStage._(this.directory, this._lock);

  static Future<TeddyUpdateStage> create(Directory parent, String archive) async {
    if (!_packageName.hasMatch(archive) || archive.endsWith('.tar')) {
      throw ArgumentError('Invalid update package name');
    }
    final directory = await parent.createTemp('.teddy-update-');
    TeddyUpdateStage? stage;
    try {
      stage = await acquire(directory);
      if (stage == null) throw const FileSystemException('Update stage is locked');
      await File(
        p.join(directory.path, _ownerFile),
      ).writeAsString(jsonEncode({'product': 'Teddy', 'format': 1, 'archive': archive}), flush: true);
      return stage;
    } catch (_) {
      await stage?.close();
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  static Future<TeddyUpdateStage?> acquire(Directory directory) async {
    final canonical = await directory.resolveSymbolicLinks();
    if (!_held.add(canonical)) return null;
    RandomAccessFile? handle;
    var acquired = false;
    try {
      final lockPath = p.join(canonical, _lockFile);
      final type = await FileSystemEntity.type(lockPath, followLinks: false);
      if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) return null;
      handle = await File(lockPath).open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive, 0, 1);
      } on FileSystemException {
        return null; // Another Teddy process may be preparing this stage.
      }
      acquired = true;
      return TeddyUpdateStage._(Directory(canonical), handle);
    } finally {
      if (!acquired) {
        await handle?.close();
        _held.remove(canonical);
      }
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try {
      await _lock.close();
    } finally {
      _held.remove(directory.path);
    }
  }
}

/// Deletes only recognized update packages and owned, never-handed-off payloads.
/// Previous bundles, logs and uncertain installer/recovery state are preserved.
Future<void> cleanupTeddyUpdates({Directory? root, DateTime? now, String? executable}) async {
  root ??= (await teddyUpdateLocation())?.parent;
  if (root == null || !await root.exists()) return;
  final cutoff = (now ?? DateTime.now()).subtract(teddyUpdateRetention);
  final running = await File(executable ?? Platform.resolvedExecutable).resolveSymbolicLinks();
  var removed = 0, failures = 0;
  await for (final entry in root.list(followLinks: false)) {
    if (entry is! Directory || !p.basename(entry.path).startsWith('.teddy-update-')) continue;
    TeddyUpdateStage? lease;
    try {
      final stagePath = await entry.resolveSymbolicLinks();
      if (p.equals(stagePath, running) || p.isWithin(stagePath, running)) continue;
      final modified = (await entry.stat()).modified;
      final children = await entry.list(followLinks: false).toList();
      final packages = children.whereType<File>().where((file) => _packageName.hasMatch(p.basename(file.path)));
      final marker = File(p.join(stagePath, _ownerFile));
      var owned = false;
      if (await FileSystemEntity.type(marker.path, followLinks: false) == FileSystemEntityType.file &&
          await marker.length() <= 16384) {
        try {
          final data = jsonDecode(await marker.readAsString());
          owned =
              data is Map &&
              data['product'] == 'Teddy' &&
              data['format'] == 1 &&
              data['archive'] is String &&
              _packageName.hasMatch(data['archive'] as String);
        } on FormatException {
          // Malformed/foreign state cannot authorize recursive deletion.
        }
      }
      if (!owned && packages.isEmpty) continue;
      lease = await TeddyUpdateStage.acquire(entry);
      if (lease == null) continue;
      for (final package in packages) {
        if ((await package.stat()).modified.isAfter(cutoff)) continue;
        await package.delete();
        removed++;
      }
      // A helper may still be using new/, or need it to recover from failure.
      // Legacy stages have no ownership manifest, so only their known packages
      // are eligible; arbitrary directories are never removed by name alone.
      final recovery = [
        'ready',
        'previous',
        'install.log',
      ].any((name) => children.any((child) => p.basename(child.path) == name));
      if (owned && !recovery && !(await marker.stat()).modified.isAfter(cutoff)) {
        final payload = Directory(p.join(stagePath, 'new'));
        if (await FileSystemEntity.type(payload.path, followLinks: false) == FileSystemEntityType.directory &&
            !(await payload.stat()).modified.isAfter(cutoff)) {
          await payload.delete(recursive: true);
          removed++;
        }
      }
      final remaining = await entry.list(followLinks: false).toList();
      final stageOld = owned ? !(await marker.stat()).modified.isAfter(cutoff) : !modified.isAfter(cutoff);
      if (stageOld &&
          remaining.every(
            (child) => child is File && [_ownerFile, _lockFile, 'cancel'].contains(p.basename(child.path)),
          )) {
        // Windows cannot unlink our open lock. Release it before removing only
        // these small metadata files, then remove the directory nonrecursively.
        await lease.close();
        lease = null;
        for (final child in remaining) {
          await child.delete();
        }
        await entry.delete();
      }
    } on FileSystemException {
      failures++;
    } finally {
      await lease?.close();
    }
  }
  if (removed > 0) appLogger.i('Update cleanup removed $removed stale package/payload entries');
  if (failures > 0) appLogger.w('Update cleanup could not clean $failures stages; will retry later');
}

/// Nonblocking, single-flight maintenance independent of login or settings UI.
class TeddyUpdateCleanup {
  final Future<void> Function() _sweep;
  final DateTime Function() _now;
  Timer? _timer;
  Future<void>? _running;
  DateTime? _lastRun;
  TeddyUpdateCleanup({Future<void> Function()? sweep, DateTime Function()? now})
    : _sweep = sweep ?? cleanupTeddyUpdates,
      _now = now ?? DateTime.now;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(teddyUpdateCleanupInterval, (_) => check());
    check();
  }

  void check() {
    if (_timer == null || _running != null) return;
    final now = _now();
    if (_lastRun != null && now.difference(_lastRun!) < teddyUpdateCleanupInterval) return;
    _lastRun = now;
    _running = Future<void>.sync(_sweep)
        .catchError((Object error) {
          appLogger.w('Update cleanup failed (${error.runtimeType}); will retry later');
        })
        .whenComplete(() => _running = null);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
