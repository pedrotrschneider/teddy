import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_downloads.dart';
import 'package:plezy/ted/ted_download_tree.dart';
import 'package:plezy/ted/ted_download_watch.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'ted_download_tree_test.dart' show file;
import 'ted_auth_test.dart' show MemoryStore, pair, response;

class EpisodeArtClient extends TedClient {
  int titles = 0;
  final entered = Completer<void>(), release = Completer<void>(), canceled = Completer<void>();
  bool hold = false;
  EpisodeArtClient(super.auth);
  @override
  Future<String> originalLanguage(TedMediaIdentity media, {bool Function()? current}) async => 'ja';
  TedMetadataSnapshot snapshot(String type) => TedMetadataSnapshot(
    id: '88888888-8888-4888-8888-888888888888',
    status: 'ready',
    generation: 1,
    name: type,
    overview: '',
    type: type,
    images: [const TedMetadataAsset('77777777-7777-4777-8777-777777777777', 'Primary', 0, 'ready')],
  );
  @override
  Future<TedTitle> title(TedMediaIdentity media) async {
    titles++;
    if (hold) {
      entered.complete();
      await release.future;
    }
    return TedTitle(media, 'Episode', '', false, 0, 0, false, enrichment: snapshot('Episode'));
  }

  @override
  Future<TedMetadataSnapshot> season(String id, int season) async => snapshot('Season');
  @override
  Future<Uint8List?> metadataImage(String id) async => Uint8List.fromList([1, 2, 3]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('offline completion waits for 95 percent and explicit Next still wins below five percent', () {
    const media = TedMediaIdentity('episode', 'tt1234567:1:1');
    const state = TedDownloadWatch(media, false, false, 0, 100000, null, null);
    final at = DateTime.utc(2026, 10, 25);
    Map<String, dynamic> event(int position, String kind) => {
      'observed_at': at.toIso8601String(),
      'position_ms': position,
      'duration_ms': 100000,
      'kind': kind,
      'natural_eof': true,
    };
    final before = state.withLocal(event(94999, 'stop'), 100000);
    expect(before.played, false);
    expect(before.inProgress, true);
    expect(before.positionMs, 94999);
    expect(before.completedAt, isNull);
    for (final input in [event(95000, 'progress'), event(1000, 'complete')]) {
      final completed = state.withLocal(input, 100000);
      expect(completed.played, true);
      expect(completed.inProgress, false);
      expect(completed.positionMs, 0);
      expect(completed.completedAt, at);
    }
  });

  test('completion must follow the copy date; older/unknown completion never hides current progress', () {
    const media = TedMediaIdentity('movie', 'tt1234567');
    final downloaded = DateTime.utc(2026, 10, 12, 12),
        before = DateTime.utc(2026, 10, 11),
        after = DateTime.utc(2026, 10, 12, 13);
    for (final completed in [before, downloaded, null]) {
      final state = TedDownloadWatch(media, true, false, 0, 10000, after, completed);
      expect(state.watchedAfter(downloaded), false);
    }
    expect(TedDownloadWatch(media, true, false, 0, 10000, after, after).watchedAfter(downloaded), true);
    final rewatch = TedDownloadWatch(media, true, true, 2000, 10000, after, before);
    expect(rewatch.watchedAfter(downloaded), false);
    expect(rewatch.positionMs, 2000);
    expect(TedDownloadWatch(media, false, false, 0, 10000, after, after).watchedAfter(downloaded), false);
    final earlyEof = rewatch.withLocal({
      'observed_at': after.add(const Duration(seconds: 1)).toIso8601String(),
      'position_ms': 2000,
      'duration_ms': 0,
      'kind': 'stop',
      'natural_eof': true,
    }, 10000);
    expect(earlyEof.inProgress, true);
    expect(earlyEof.completedAt, before);
  });

  test('saved copy boundary and account state survive stale file saves, outage and offline viewing', () async {
    final root = await Directory.systemTemp.createTemp('ted-copy-watch-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    const media = TedMediaIdentity('movie', 'tt1234567');
    final before = DateTime.utc(2026, 10, 11),
        downloaded = DateTime.utc(2026, 10, 12, 12),
        after = DateTime.utc(2026, 10, 12, 13);
    var server = TedDownloadWatch(media, true, true, 2500, 10000, before, before), outage = false;
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/watch-state')) {
          if (outage) return response({}, 503);
          return response({
            'items': [server.toJson()],
          });
        }
        return response(pair(DateTime.now()));
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Copy watch');
    final scope = tedOfflineScope(auth)!;
    final saved = file(scope, 1, media, 'Movie')..remove('downloaded_at');
    // A paused publication attempt has not fixed the copy's boundary yet.
    await store.saveDownload(scope, {...saved, 'status': 'paused', 'downloaded_at': before.toIso8601String()});
    await store.saveDownload(scope, saved);
    final dir = Directory('${root.path}/${saved['id']}');
    await dir.create();
    final copy = File('${dir.path}/media.bin');
    await copy.writeAsBytes(List.filled(10, 0));
    await copy.setLastModified(downloaded);
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      transferTask: (_) async => throw StateError('No media transfer'),
      cancelTask: (_) async => true,
    );
    addTearDown(manager.dispose);
    final first = (await manager.watchStates([saved]))[media]!;
    expect(first.watchedAfter(downloaded), false);
    expect(first.positionMs, 2500);
    expect(DateTime.parse(saved['downloaded_at'] as String), downloaded);
    server = TedDownloadWatch(media, true, false, 0, 10000, after, after);
    await manager.watchStates(await manager.list());
    await store.saveDownload(scope, {...saved, 'downloaded_at': after.toIso8601String()});
    final retained = (await manager.list()).single;
    expect(DateTime.parse(retained['downloaded_at'] as String), downloaded);
    expect(
      TedDownloadWatch.fromJson(retained['download_watch'] as Map<String, dynamic>).watchedAfter(downloaded),
      true,
    );
    outage = true;
    final localAt = after.add(const Duration(hours: 1));
    await store.record(scope, TedPlaybackSession('99999999-9999-4999-8999-999999999999', media, '/local', 10000, 0), {
      'id': '11111111-1111-4111-8111-111111111111',
      'kind': 'stop',
      'observed_at': localAt.toIso8601String(),
      'sequence': 1,
      'position_ms': 9500,
      'duration_ms': 10000,
    }, offline: true);
    final local = (await manager.watchStates(await manager.list()))[media]!;
    expect(local.watchedAfter(downloaded), true);
    expect(local.completedAt, localAt);
    expect(await store.pending(scope), 1);
    // On reconnect a newer explicit unwatched decision wins over local history.
    outage = false;
    server = TedDownloadWatch(media, false, false, 0, 10000, localAt.add(const Duration(hours: 1)), after);
    expect((await manager.watchStates(await manager.list()))[media]!.watchedAfter(downloaded), false);
    await manager.shutdown();
  });

  test('every completed episode caches its own thumbnail and reuses it offline', () async {
    final root = await Directory.systemTemp.createTemp('ted-episode-cache-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Art');
    final store = TedLocalStore(db), scope = tedOfflineScope(auth)!, client = EpisodeArtClient(auth);
    final manager = TedDownloads(
      client,
      store,
      root,
      transferTask: (_) async => throw StateError('No transfer'),
      cancelTask: (_) async {
        if (client.hold && !client.canceled.isCompleted) client.canceled.complete();
        return true;
      },
    );
    addTearDown(manager.dispose);
    final values = [
      for (var i = 1; i <= 2; i++) file(scope, i, TedMediaIdentity('episode', 'tt1234567:1:$i'), 'Episode $i'),
    ];
    for (final value in values) {
      await store.saveDownload(scope, value);
      await manager.directory(value['id'] as String).create();
      await File('${manager.directory(value['id'] as String).path}/media.bin').writeAsBytes(List.filled(10, 0));
      await manager.cacheFolderArtwork(value);
      expect(await File('${manager.directory(value['id'] as String).path}/thumbnail.image').readAsBytes(), [1, 2, 3]);
      await manager.cacheFolderArtwork(value);
    }
    expect(client.titles, 2);
    for (final saved in await manager.list()) {
      expect((await manager.offlineSession(saved)).originalLanguage, 'ja');
    }
    final movie = file(scope, 4, const TedMediaIdentity('movie', 'tt7654321'), 'Existing movie');
    await store.saveDownload(scope, movie);
    await manager.directory(movie['id'] as String).create();
    await File('${manager.directory(movie['id'] as String).path}/media.bin').writeAsBytes(List.filled(10, 0));
    await manager.cacheFolderArtwork(movie);
    final cachedMovie = (await manager.list()).singleWhere((v) => v['id'] == movie['id']);
    expect((await manager.offlineSession(cachedMovie)).originalLanguage, 'ja');
    await manager.remove(cachedMovie);
    final tree = tedDownloadTree(manager, values, [], {});
    expect(tree.single.children.single.children.every((v) => v.artwork!.endsWith('/thumbnail.image')), true);
    client.hold = true;
    final third = file(scope, 3, const TedMediaIdentity('episode', 'tt1234567:1:3'), 'Three');
    await store.saveDownload(scope, third);
    await manager.directory(third['id'] as String).create();
    final caching = manager.cacheFolderArtwork(third);
    await client.entered.future;
    final canceled = expectLater(caching, throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'download_paused')));
    final removing = manager.removeSelection({const TedMediaIdentity('episode', 'tt1234567:1:3')});
    await client.canceled.future;
    client.release.complete();
    await canceled;
    await removing;
    expect(await manager.directory(third['id'] as String).exists(), false);
    expect((await manager.list()).length, 2);
    await manager.shutdown();
  });

  test('watch-state batches reject partial, duplicate and unrelated responses', () async {
    const first = TedMediaIdentity('movie', 'tt1234567'), second = TedMediaIdentity('episode', 'tt1234567:1:1');
    Map<String, dynamic> state(TedMediaIdentity media) =>
        TedDownloadWatch(media, false, false, 0, null, null, null).toJson();
    var items = <Map<String, dynamic>>[];
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient(
        (r) async => r.url.path.endsWith('/watch-state') ? response({'items': items}) : response(pair(DateTime.now())),
      ),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Batch');
    final client = TedClient(auth);
    for (final invalid in [
      [state(first)],
      [state(first), state(first)],
      [state(first), state(const TedMediaIdentity('movie', 'tt7654321'))],
    ]) {
      items = invalid;
      await expectLater(client.downloadWatches([first, second]), throwsA(isA<TedFailure>()));
    }
    items = [state(second), state(first)];
    expect((await client.downloadWatches([first, second])).keys.toSet(), {first, second});
  });

  test('shutdown drains a held watch read without publishing its response', () async {
    final root = await Directory.systemTemp.createTemp('ted-watch-shutdown-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final entered = Completer<void>(), release = Completer<void>();
    const media = TedMediaIdentity('movie', 'tt1234567');
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/watch-state')) {
          entered.complete();
          await release.future;
          return response({
            'items': [
              TedDownloadWatch(
                media,
                true,
                false,
                0,
                null,
                DateTime.utc(2026, 10, 12, 13),
                DateTime.utc(2026, 10, 12, 13),
              ).toJson(),
            ],
          });
        }
        return response(pair(DateTime.now()));
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Shutdown');
    final store = TedLocalStore(db), scope = tedOfflineScope(auth)!;
    final value = file(scope, 1, media, 'Movie');
    await store.saveDownload(scope, value);
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      transferTask: (_) async => throw StateError('No transfer'),
      cancelTask: (_) async => true,
    );
    addTearDown(manager.dispose);
    final read = manager.watchStates([value]);
    await entered.future;
    var settled = false;
    final stopping = manager.shutdown().then((_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    expect(settled, false);
    expect(await manager.watchStates([value]), isEmpty);
    release.complete();
    expect(await read, isEmpty);
    await stopping;
    expect((await store.downloads(scope)).single['download_watch'], isNull);
  });
}
