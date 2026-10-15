import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'ted_local_store.dart';
import 'ted_models.dart';

/// A durable move journal. The database switches roots only after every owned
/// file has been copied, flushed and compared. Reports and download rows never
/// move; interrupted copies are retryable and the old root remains playable.
class TedDownloadStorage {
  final TedLocalStore store;
  final Directory defaultRoot;
  final void Function(String)? progress;
  TedDownloadStorage(this.store, this.defaultRoot, {this.progress});

  Future<Directory> root() async {
    final saved = await store.downloadStorage();
    final path = saved?['root'];
    if (path == null) return defaultRoot;
    if (path is! String || !p.isAbsolute(path)) {
      throw const FormatException('Invalid saved download location');
    }
    return Directory(path);
  }

  Future<void> move(Directory destination, List<String> ids) async {
    final source = await root();
    if (!p.isAbsolute(destination.path)) throw const FileSystemException('Choose an absolute folder path');
    await destination.create(recursive: true);
    if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.directory) {
      throw const FileSystemException('Choose a real folder, not a symbolic link');
    }
    final target = await destination.resolveSymbolicLinks();
    final origin = await source.resolveSymbolicLinks();
    final saved = await store.downloadStorage();
    if (saved?['move'] != null) {
      if ((saved!['move'] as Map)['to'] != target) {
        throw const FileSystemException('Finish the pending download move first');
      }
      await resume();
      return;
    }
    if (origin == target) return;
    if (p.isWithin(origin, target) || p.isWithin(target, origin) || !p.isAbsolute(destination.path)) {
      throw const FileSystemException('Choose a separate download folder');
    }
    final files = <Map<String, dynamic>>[];
    for (final id in ids) {
      if (!tedUuid(id)) throw const FormatException('Invalid download identity');
      final dir = Directory(p.join(origin, id));
      if (!await dir.exists()) continue;
      if (await FileSystemEntity.type(dir.path, followLinks: false) != FileSystemEntityType.directory) {
        throw const FileSystemException('Download contains a symbolic link');
      }
      if (await FileSystemEntity.type(p.join(target, id), followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Destination already contains a download folder');
      }
      await for (final entry in dir.list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (entry is! File || !ownedFile(name)) throw const FileSystemException('Unexpected file in download folder');
        files.add({
          'id': id,
          'name': name,
          'bytes': await entry.length(),
          'modified': (await entry.stat()).modified.toUtc().toIso8601String(),
          'digest': (await sha256.bind(entry.openRead()).first).toString(),
        });
      }
    }
    await store.saveDownloadStorage({
      'root': origin,
      'move': {'id': const Uuid().v4(), 'from': origin, 'to': target, 'files': files, 'committed': false},
    });
    await resume();
  }

  static bool ownedFile(String name) => RegExp(
    r'^(media\.(bin|partial)|chunk|(?:poster|thumbnail|show|season|background|logo)\.image(?:\.tmp)?|sub-\d+\.(srt|vtt|ass|ssa)(?:\.tmp)?)$',
  ).hasMatch(name);

  Future<bool> _matches(File file, Map<String, dynamic> value) async =>
      await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.file &&
      await file.length() == value['bytes'] &&
      (await sha256.bind(file.openRead()).first).toString() == value['digest'];

  Future<void> resume() async {
    final saved = await store.downloadStorage();
    if (saved?['move'] == null) return;
    final move = Map<String, dynamic>.from(saved!['move'] as Map);
    final from = move['from'], to = move['to'], moveId = move['id'];
    if (from is! String ||
        to is! String ||
        !p.isAbsolute(from) ||
        !p.isAbsolute(to) ||
        p.isWithin(from, to) ||
        p.isWithin(to, from) ||
        from == to ||
        !tedUuid(moveId)) {
      throw const FormatException('Invalid download move journal');
    }
    for (final path in [from, to]) {
      if (await Directory(path).resolveSymbolicLinks() != path) {
        throw const FileSystemException('Download folder has changed');
      }
    }
    final files = (move['files'] as List).map((v) => Map<String, dynamic>.from(v as Map)).toList();
    for (final file in files) {
      if (!tedUuid(file['id']) ||
          file['name'] is! String ||
          !ownedFile(file['name']) ||
          file['bytes'] is! int ||
          (file['bytes'] as int) < 0 ||
          file['digest'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(file['digest'])) {
        throw const FormatException('Invalid download move member');
      }
      for (final path in [p.join(from, file['id']), p.join(to, file['id'])]) {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type != FileSystemEntityType.directory && type != FileSystemEntityType.notFound) {
          throw const FileSystemException('Download member folder has changed');
        }
      }
    }
    if (move['committed'] != true) {
      for (var i = 0; i < files.length; i++) {
        progress?.call('Moving files ${i + 1} of ${files.length}');
        final value = files[i];
        final source = File(p.join(from, value['id'], value['name']));
        final target = File(p.join(to, value['id'], value['name']));
        if (!await _matches(source, value)) throw const FileSystemException('Source download has changed');
        final parent = target.parent;
        if (await FileSystemEntity.type(parent.path, followLinks: false) == FileSystemEntityType.link) {
          throw const FileSystemException('Destination download has changed');
        }
        await parent.create(recursive: true);
        if (await target.exists()) {
          if (!await _matches(target, value)) throw const FileSystemException('Destination file already exists');
          continue;
        }
        final temporary = File(p.join(parent.path, '.teddy-move-$moveId'));
        if (await FileSystemEntity.type(temporary.path, followLinks: false) == FileSystemEntityType.link) {
          throw const FileSystemException('Unsafe move staging path');
        }
        final output = await temporary.open(mode: FileMode.write);
        try {
          await for (final chunk in source.openRead()) {
            await output.writeFrom(chunk);
          }
          await output.flush();
        } finally {
          await output.close();
        }
        if (!await _matches(temporary, value)) throw const FileSystemException('Download copy verification failed');
        await temporary.setLastModified(DateTime.parse(value['modified'] as String));
        await temporary.rename(target.path);
      }
      // Check all published files again before the only activation boundary.
      for (final file in files) {
        if (!await _matches(File(p.join(to, file['id'], file['name'])), file)) {
          throw const FileSystemException('Download copy verification failed');
        }
      }
      move['committed'] = true;
      await store.saveDownloadStorage({'root': to, 'move': move});
    }
    progress?.call('Removing verified old copies');
    for (final file in files) {
      final source = File(p.join(from, file['id'], file['name']));
      if (!await _matches(File(p.join(to, file['id'], file['name'])), file)) {
        throw const FileSystemException('Retaining old copy: destination changed');
      }
      if (await source.exists()) {
        if (!await _matches(source, file)) throw const FileSystemException('Retaining changed old copy');
        await source.delete();
      }
    }
    for (final id in files.map((v) => v['id'] as String).toSet()) {
      final folder = Directory(p.join(from, id));
      if (await folder.exists() && await folder.list().isEmpty) await folder.delete();
    }
    await store.saveDownloadStorage({'root': to == await defaultRoot.resolveSymbolicLinks() ? null : to});
  }
}
