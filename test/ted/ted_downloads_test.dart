import 'dart:async';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/prefs.dart';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_downloads.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;

const id = '44444444-4444-4444-8444-444444444444';
const session = '33333333-3333-4333-8333-333333333333';
final etag = '"ted-${'a' * 64}"';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });

  test('chunk setting is reread between validated ranges without changing release or checkpoint', () async {
    final root = await Directory.systemTemp.createTemp('teddy-chunk-setting-');
    addTearDown(() => root.delete(recursive: true));
    final store = TedLocalStore(AppDatabase.forTesting(NativeDatabase.memory()));
    addTearDown(store.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'chunk test');
    final settings = SettingsService.instance;
    await settings.write(SettingsService.teddyDownloadChunkMiB, 8);
    const size = 24 * 1024 * 1024;
    final value = <String, dynamic>{
      'id': id,
      'scope': tedOfflineScope(auth)!,
      'media': const TedMediaIdentity('movie', 'tt1234567').toJson(),
      'session': session,
      'url': '/api/client/v1/downloads/$session/media',
      'etag': etag,
      'bytes': size,
      'received': 0,
      'status': 'paused',
      'images': <String, dynamic>{},
      'subtitles': <dynamic>[],
    };
    final ranges = <String>[];
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      cancelTask: (_) async => true,
      transferTask: (task) async {
        ranges.add(task.headers['Range']!);
        final tuple = task.headers['Range']!.substring(6).split('-').map(int.parse).toList();
        expect(task.baseDirectory, BaseDirectory.root);
        // The native downloader stores a root-relative directory (stripping
        // the POSIX leading slash), then joins it with its root base path.
        expect(task.directory, '${root.path}/$id'.replaceFirst(RegExp(r'^/'), ''));
        final chunk = await File('${root.path}/$id/chunk').open(mode: FileMode.write);
        await chunk.setPosition(tuple[1] - tuple[0]);
        await chunk.writeByte(0);
        await chunk.flush();
        await chunk.close();
        if (ranges.length == 1) await settings.write(SettingsService.teddyDownloadChunkMiB, 16);
        return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
          'content-range': 'bytes ${tuple[0]}-${tuple[1]}/$size',
          'etag': etag,
        }, 206);
      },
    );
    addTearDown(manager.dispose);
    await store.saveDownload(tedOfflineScope(auth)!, value);
    await manager.resume(value);
    expect(ranges, ['bytes=0-8388607', 'bytes=8388608-25165823']);
    final saved = (await manager.list()).single;
    expect(saved['received'], size);
    expect(saved['session'], session);
    expect(saved['status'], 'complete');
  });
  test('application shutdown fences a held transfer and retains the last durable checkpoint', () async {
    final root = await Directory.systemTemp.createTemp('teddy-download-exit-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Shutdown fixture');
    final scope = tedOfflineScope(auth)!;
    final saved = <String, dynamic>{
      'id': id,
      'scope': scope,
      'media': const TedMediaIdentity('movie', 'tt1234567').toJson(),
      'session': session,
      'url': '/api/client/v1/downloads/$session/media',
      'bytes': 10,
      'received': 4,
      'etag': etag,
      'status': 'paused',
      'images': <String, dynamic>{},
      'subtitles': <dynamic>[],
    };
    await store.saveDownload(scope, saved);
    await Directory('${root.path}/$id').create();
    await File('${root.path}/$id/media.partial').writeAsBytes([1, 2, 3, 4]);
    final entered = Completer<void>(), release = Completer<void>();
    late DownloadTask task;
    final cancelled = <String>[];
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      transferTask: (next) async {
        task = next;
        entered.complete();
        await release.future;
        return TaskStatusUpdate(task, TaskStatus.canceled);
      },
      cancelTask: (id) async {
        cancelled.add(id);
        return true;
      },
    );
    addTearDown(manager.dispose);
    final transfer = manager.resume(saved);
    await entered.future;
    var finished = false;
    final shutdown = manager.shutdown().then((_) => finished = true);
    expect(finished, false);
    await expectLater(manager.resume(saved), throwsA(isA<TedFailure>()));
    release.complete();
    await transfer;
    await shutdown;
    expect(cancelled, ['teddy-$id']);
    final retained = (await store.downloads(scope)).single;
    expect(retained['status'], 'paused');
    expect(retained['received'], 4);
    expect(await File('${root.path}/$id/media.partial').readAsBytes(), [1, 2, 3, 4]);
    expect(await File('${root.path}/$id/media.bin').exists(), false);
  });
  test('a rejected access header renews through one auth owner and retries the same byte range', () async {
    final root = await Directory.systemTemp.createTemp('teddy-access-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    var rotations = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/refresh')) {
          rotations++;
          return response(pair(DateTime.now(), suffix: 'b'));
        }
        return response(pair(DateTime.now()));
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final scope = tedOfflineScope(auth)!;
    final v = <String, dynamic>{
      'id': id,
      'scope': scope,
      'media': const TedMediaIdentity('movie', 'tt1234567').toJson(),
      'session': session,
      'url': '/api/client/v1/downloads/$session/media',
      'bytes': 10,
      'received': 0,
      'etag': etag,
      'status': 'paused',
      'images': <String, dynamic>{},
      'subtitles': <dynamic>[],
    };
    final requests = <DownloadTask>[];
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      cancelTask: (_) async => true,
      transferTask: (task) async {
        requests.add(task);
        if (requests.length == 1) return TaskStatusUpdate(task, TaskStatus.failed, null, null, {}, 401);
        await File('${root.path}/$id/chunk').writeAsBytes(List.filled(10, 8));
        return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
          'content-range': 'bytes 0-9/10',
          'etag': etag,
        }, 206);
      },
    );
    addTearDown(manager.dispose);
    await store.saveDownload(scope, v);
    await manager.resume(v);
    expect(rotations, 1);
    expect(requests.length, 2);
    expect(requests[0].url, requests[1].url);
    expect(requests[0].headers['Range'], requests[1].headers['Range']);
    expect(requests[0].headers['If-Match'], requests[1].headers['If-Match']);
    expect(requests[0].headers['Authorization'], isNot(requests[1].headers['Authorization']));
    expect((await manager.list()).single['status'], 'complete');
  });

  test('pause during artwork acquisition retains completed byte checkpoints and resumes assets', () async {
    final root = await Directory.systemTemp.createTemp('teddy-assets-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final entered = Completer<void>(), release = Completer<void>();
    var assetCalls = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return response(pair(DateTime.now()));
        if (++assetCalls == 1) {
          entered.complete();
          await release.future;
        }
        return response({'image': 'fixture'});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final scope = tedOfflineScope(auth)!;
    final v = <String, dynamic>{
      'id': id,
      'scope': scope,
      'media': const TedMediaIdentity('movie', 'tt1234567').toJson(),
      'session': session,
      'url': '/api/client/v1/downloads/$session/media',
      'bytes': 10,
      'received': 0,
      'etag': etag,
      'status': 'paused',
      'images': {'poster': 'https://art.example/poster'},
      'subtitles': <dynamic>[],
    };
    var transfers = 0;
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      cancelTask: (_) async => true,
      transferTask: (task) async {
        transfers++;
        await File('${root.path}/$id/chunk').writeAsBytes(List.filled(10, 8));
        return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
          'content-range': 'bytes 0-9/10',
          'etag': etag,
        }, 206);
      },
    );
    addTearDown(manager.dispose);
    await store.saveDownload(scope, v);
    final download = manager.resume(v);
    await entered.future;
    final paused = manager.pause(id);
    release.complete();
    await paused;
    await download;
    final saved = (await manager.list()).single;
    expect(saved['status'], 'paused');
    expect(saved['received'], 10);
    expect(await File('${root.path}/$id/media.bin').exists(), false);
    await manager.resume(saved);
    expect(transfers, 1);
    expect((await manager.list()).single['status'], 'complete');
  });
  test('range validation refuses whole responses, changed releases and truncated bytes', () {
    final d = TedDownloadDescriptor.parse({
      'session_id': session,
      'media_url': '/api/client/v1/downloads/$session/media',
      'bytes': 100,
      'etag': etag,
    }, session);
    final headers = {'content-range': 'bytes 10-19/100', 'etag': etag};
    d.validateRange(206, headers, 10, 19, 10);
    expect(() => d.validateRange(200, headers, 10, 19, 10), throwsA(isA<TedFailure>()));
    expect(() => d.validateRange(206, {...headers, 'etag': 'changed'}, 10, 19, 10), throwsA(isA<TedFailure>()));
    expect(() => d.validateRange(206, headers, 10, 19, 9), throwsA(isA<TedFailure>()));
  });

  test('512 MiB ranges resume from an existing prefix and pause without committing transient bytes', () async {
    final root = await Directory.systemTemp.createTemp('teddy-large-pause-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Large ranges');
    final scope = tedOfflineScope(auth)!;
    const size = 512 * 1024 * 1024;
    final saved = <String, dynamic>{
      'id': id,
      'scope': scope,
      'media': const TedMediaIdentity('movie', 'tt1234567').toJson(),
      'session': session,
      'url': '/api/client/v1/downloads/$session/media',
      'bytes': size + 14,
      'received': 4,
      'etag': etag,
      'status': 'paused',
      'images': <String, dynamic>{},
      'subtitles': <dynamic>[],
    };
    await store.saveDownload(scope, saved);
    final dir = Directory('${root.path}/$id');
    await dir.create();
    await File('${dir.path}/media.partial').writeAsBytes([1, 2, 3, 4]);
    final entered = [Completer<void>(), Completer<void>()], release = [Completer<void>(), Completer<void>()];
    var requests = 0;
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      cancelTask: (_) async => true,
      progressTransferTask: (task, report) async {
        final attempt = requests++;
        expect(task.headers['Range'], 'bytes=4-${size + 3}');
        expect(task.headers['If-Match'], etag);
        report(.8); // Native progress must never become a durable checkpoint.
        await File('${dir.path}/chunk').writeAsBytes([9, 9]);
        entered[attempt].complete();
        await release[attempt].future;
        return TaskStatusUpdate(task, TaskStatus.canceled);
      },
    );
    addTearDown(manager.dispose);
    for (var attempt = 0; attempt < 2; attempt++) {
      final work = manager.resume((await store.downloads(scope)).single);
      await entered[attempt].future;
      final pausing = manager.pause(id);
      release[attempt].complete();
      await work;
      await pausing;
      final retained = (await store.downloads(scope)).single;
      expect(retained['received'], 4);
      expect(retained['status'], 'paused');
      expect(await File('${dir.path}/media.partial').readAsBytes(), [1, 2, 3, 4]);
      expect(await File('${dir.path}/media.bin').exists(), false);
    }
    expect(requests, 2);
    await manager.shutdown();
  });

  test('a truncated large range retains the saved prefix and is never published', () async {
    final root = await Directory.systemTemp.createTemp('teddy-large-truncated-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Truncated range');
    final scope = tedOfflineScope(auth)!;
    const size = 512 * 1024 * 1024;
    final saved = <String, dynamic>{
      'id': id,
      'scope': scope,
      'media': const TedMediaIdentity('movie', 'tt1234567').toJson(),
      'session': session,
      'url': '/api/client/v1/downloads/$session/media',
      'bytes': size + 14,
      'received': 4,
      'etag': etag,
      'status': 'paused',
      'images': <String, dynamic>{},
      'subtitles': <dynamic>[],
    };
    await store.saveDownload(scope, saved);
    final dir = Directory('${root.path}/$id');
    await dir.create();
    await File('${dir.path}/media.partial').writeAsBytes([1, 2, 3, 4]);
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      cancelTask: (_) async => true,
      transferTask: (task) async {
        await File('${dir.path}/chunk').writeAsBytes([5, 6]);
        return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
          'content-range': 'bytes 4-${size + 3}/${size + 14}',
          'etag': etag,
        }, 206);
      },
    );
    addTearDown(manager.dispose);
    await manager.resume(saved);
    final retained = (await store.downloads(scope)).single;
    expect(retained['received'], 4);
    expect(retained['status'], 'failed');
    expect(retained['error'], 'download_changed');
    expect(await File('${dir.path}/media.partial').readAsBytes(), [1, 2, 3, 4]);
    expect(await File('${dir.path}/media.bin').exists(), false);
    await manager.shutdown();
  });

  test('resume truncates uncommitted bytes and publishes only the validated selected release', () async {
    final root = await Directory.systemTemp.createTemp('teddy-download-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((r) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'download');
    final scope = tedOfflineScope(auth)!;
    final v = <String, dynamic>{
      'id': id,
      'scope': scope,
      'media': const TedMediaIdentity('movie', 'tt1234567').toJson(),
      'session': session,
      'url': '/api/client/v1/downloads/$session/media',
      'bytes': 10,
      'received': 4,
      'etag': etag,
      'status': 'paused',
      'images': <String, dynamic>{},
      'subtitles': <dynamic>[],
    };
    final dir = Directory('${root.path}/$id');
    await dir.create();
    await File('${dir.path}/media.partial').writeAsBytes([1, 2, 3, 4, 99, 99]);
    await store.saveDownload(scope, v);
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      cancelTask: (_) async => true,
      transferTask: (task) async {
        expect(task.headers['Range'], 'bytes=4-9');
        expect(task.headers['If-Match'], etag);
        expect(task.headers['Authorization'], startsWith('Bearer '));
        await File('${dir.path}/chunk').writeAsBytes([5, 6, 7, 8, 9, 10]);
        return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
          'content-range': 'bytes 4-9/10',
          'etag': etag,
        }, 206);
      },
    );
    addTearDown(manager.dispose);
    await manager.resume(v);
    expect(await File('${dir.path}/media.bin').readAsBytes(), List.generate(10, (i) => i + 1));
    final saved = (await manager.list()).single;
    expect(saved['status'], 'complete');
    expect(saved['received'], 10);
    // Malformed recovery state cannot redirect credentials or escape the owned
    // directory. Keep the legitimate completed file and record untouched.
    await expectLater(manager.resume({...saved, 'url': 'https://private.invalid/file'}), throwsA(isA<TedFailure>()));
    await expectLater(
      manager.retryAssets({...saved, 'original_language': 'not a language'}),
      throwsA(isA<TedFailure>()),
    );
    await expectLater(
      manager.retryAssets({
        ...saved,
        'images': {'../../outside': 'https://example.invalid/image'},
      }),
      throwsA(isA<TedFailure>()),
    );
    expect(await File('${dir.path}/media.bin').length(), 10);
    manager.beginPlaying(id);
    await expectLater(manager.remove(saved), throwsA(isA<TedFailure>()));
    manager.endPlaying(id);
    await manager.remove(saved);
    expect(await manager.list(), isEmpty);
    expect(await dir.exists(), false);
  });

  test('changed range and an account switch never append or publish a chunk', () async {
    for (final switchAccount in [false, true]) {
      final root = await Directory.systemTemp.createTemp('teddy-fenced-');
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final store = TedLocalStore(db);
      final auth = TedAuth(store: MemoryStore(), client: MockClient((r) async => response(pair(DateTime.now()))));
      await auth.login('https://ted.example', 'fixture', '', 'test');
      final scope = tedOfflineScope(auth)!;
      final v = <String, dynamic>{
        'id': id,
        'scope': scope,
        'media': const TedMediaIdentity('movie', 'tt1234567').toJson(),
        'session': session,
        'url': '/api/client/v1/downloads/$session/media',
        'bytes': 10,
        'received': 0,
        'etag': etag,
        'status': 'paused',
        'images': <String, dynamic>{},
        'subtitles': <dynamic>[],
      };
      await store.saveDownload(scope, v);
      final entered = Completer<void>(), release = Completer<void>();
      final manager = TedDownloads(
        TedClient(auth),
        store,
        root,
        cancelTask: (_) async => true,
        transferTask: (task) async {
          entered.complete();
          await release.future;
          await File('${root.path}/$id/chunk').writeAsBytes(List.filled(10, 7));
          return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
            'content-range': 'bytes 0-9/10',
            'etag': '"changed"',
          }, 206);
        },
      );
      final work = manager.resume(v);
      await entered.future;
      if (switchAccount) await auth.login('https://other.example', 'fixture', '', 'test');
      release.complete();
      await work;
      expect(await File('${root.path}/$id/media.bin').exists(), false);
      expect((await store.downloads(scope)).single['received'], 0);
      if (switchAccount) expect(await manager.list(), isEmpty);
      manager.dispose();
      auth.close();
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
