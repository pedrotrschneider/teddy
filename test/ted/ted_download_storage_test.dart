import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_download_storage.dart';
import 'package:plezy/ted/ted_local_store.dart';

const id = '44444444-4444-4444-8444-444444444444';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory area, source, target;
  late TedLocalStore store;
  setUp(() async {
    area = await Directory.systemTemp.createTemp('teddy-move-');
    source = await Directory(p.join(area.path, 'old')).create();
    target = await Directory(p.join(area.path, 'new')).create();
    store = TedLocalStore(AppDatabase.forTesting(NativeDatabase(File(p.join(area.path, 'device.sqlite')))));
    await Directory(p.join(source.path, id)).create();
    await File(p.join(source.path, id, 'media.bin')).writeAsBytes(List.generate(10000, (i) => i % 256), flush: true);
    await File(p.join(source.path, id, 'thumbnail.image')).writeAsBytes([1, 2, 3], flush: true);
  });
  tearDown(() async {
    await store.close();
    await area.delete(recursive: true);
  });
  test('verified move and reset preserve unrelated files and device identity', () async {
    final device = await store.installationDevice();
    await File(p.join(source.path, 'personal.txt')).writeAsString('keep');
    final storage = TedDownloadStorage(store, source);
    await storage.move(target, [id]);
    expect(await File(p.join(target.path, id, 'media.bin')).length(), 10000);
    expect(await File(p.join(source.path, id, 'media.bin')).exists(), false);
    expect(await File(p.join(source.path, 'personal.txt')).readAsString(), 'keep');
    expect((await storage.root()).path, await target.resolveSymbolicLinks());
    expect(await store.installationDevice(), device);
    await storage.move(source, [id]);
    expect((await storage.root()).path, source.path);
    expect(await File(p.join(source.path, id, 'thumbnail.image')).readAsBytes(), [1, 2, 3]);
  });
  test('interrupted copy retains old root and resumes after a real database reopen', () async {
    var calls = 0;
    final storage = TedDownloadStorage(
      store,
      source,
      progress: (_) {
        if (++calls == 2) throw const FileSystemException('Controlled copy failure');
      },
    );
    await expectLater(storage.move(target, [id]), throwsA(isA<FileSystemException>()));
    expect((await storage.root()).path, await source.resolveSymbolicLinks());
    expect(await File(p.join(source.path, id, 'media.bin')).length(), 10000);
    await store.close();
    store = TedLocalStore(AppDatabase.forTesting(NativeDatabase(File(p.join(area.path, 'device.sqlite')))));
    final reopened = TedDownloadStorage(store, source);
    await reopened.resume();
    expect((await reopened.root()).path, await target.resolveSymbolicLinks());
    expect((await store.downloadStorage())!.containsKey('move'), false);
  });
  test('collisions and symbolic links fail without overwriting destination or source', () async {
    await Directory(p.join(target.path, id)).create();
    await File(p.join(target.path, id, 'media.bin')).writeAsString('unrelated');
    await expectLater(TedDownloadStorage(store, source).move(target, [id]), throwsA(isA<FileSystemException>()));
    expect(await File(p.join(target.path, id, 'media.bin')).readAsString(), 'unrelated');
    expect(await File(p.join(source.path, id, 'media.bin')).length(), 10000);
    await Directory(p.join(target.path, id)).delete(recursive: true);
    await Link(p.join(source.path, id, 'poster.image')).create(p.join(source.path, 'personal.txt'));
    await expectLater(TedDownloadStorage(store, source).move(target, [id]), throwsA(isA<FileSystemException>()));
    expect(await store.downloadStorage(), isNull);
  });
}
