import 'dart:async';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/prefs.dart';
import 'dart:convert';
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
import 'package:plezy/ted/ted_source_models.dart';
import 'package:plezy/ted/ted_presentation.dart';
import 'package:uuid/uuid.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_catalog_test.dart' show titleData;
import 'ted_series_detail_test.dart' show SeriesDetailFixture;

class QueueClient extends SeriesDetailFixture {
  final selections = <(TedMediaIdentity, String?)>[];
  final entered = Completer<void>(), release = Completer<void>();
  bool holdPreparation = true;
  @override
  Future<TedTitle> title(TedMediaIdentity media) async {
    if (holdPreparation) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return data(media);
  }

  @override
  Future<TedSourcePage> sources(TedMediaIdentity media, {String? previousSession}) async => media.id.endsWith(':1')
      ? const TedSourcePage(true, false, [], [], null)
      : const TedSourcePage(
          false,
          false,
          [TedSourceChoice('11111111-1111-4111-8111-111111111111', 'Addon', 'First', '')],
          [],
          null,
        );
  @override
  Future<TedPlaybackSession> createSession(TedMediaIdentity media, {String? sourceId}) async {
    selections.add((media, sourceId));
    throw const TedFailure('download_unavailable');
  }
}

class IncompleteSeasonQueueClient extends QueueClient {
  @override
  Future<TedEpisodePage> episodes(String id, int season, {int? after}) async {
    if (after != null) throw const TedFailure('catalog_unavailable');
    return TedEpisodePage([data(TedMediaIdentity('episode', '$id:$season:1'))], 1);
  }
}

/// Seed the durable intents produced by the preceding app. New production
/// requests use the reviewed source plan; these cases verify existing recovery.
Future<void> seedExistingQueue(TedDownloads manager, TedTitle show, {int? season}) async {
  final owner = manager.scope!;
  final titles = await manager.client.allEpisodes(show, season: season);
  final existing = (await manager.store.downloads(owner)).map((v) => jsonEncode(v['media'])).toSet();
  await manager.store.enqueueDownloads(owner, [
    for (final title in titles)
      if (!existing.contains(jsonEncode(title.media.toJson())))
        {
          'id': const Uuid().v4(),
          'scope': owner,
          'media': title.media.toJson(),
          'name': title.name,
          'metadata': TedPresentation(manager.client).item(title).toJson(),
          'status': 'queued',
        },
  ]);
  manager.pumpQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });
  Future<void> login(TedAuth auth) => auth.login('https://ted.example', 'fixture', '', 'Queue test');
  test('season deletion fences held source preparation before deleting persistent queue intents', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-season-remove-');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final client = QueueClient();
    addTearDown(client.auth.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    await login(auth);
    addTearDown(auth.close);
    final cancelled = Completer<void>();
    final store = TedLocalStore(db);
    final manager = TedDownloads(
      _OwnedQueueClient(auth, client),
      store,
      dir,
      cancelTask: (_) async {
        if (!cancelled.isCompleted) cancelled.complete();
        return true;
      },
    );
    addTearDown(manager.dispose);
    await seedExistingQueue(manager, client.data(const TedMediaIdentity('series', 'tt4000000')), season: 1);
    await client.entered.future;
    const preparedId = '44444444-4444-4444-8444-444444444444';
    const preparedSession = '33333333-3333-4333-8333-333333333333';
    await store.saveDownload(manager.scope!, {
      'id': preparedId,
      'scope': manager.scope,
      'media': const TedMediaIdentity('episode', 'tt4000000:1:2').toJson(),
      'session': preparedSession,
      'url': '/api/client/v1/downloads/$preparedSession/media',
      'etag': '"ted-${'a' * 64}"',
      'bytes': 10,
      'received': 0,
      'status': 'paused',
      'images': <String, dynamic>{},
      'subtitles': <dynamic>[],
    });
    var finished = false;
    final removing = manager
        .removeSelection({
          const TedMediaIdentity('episode', 'tt4000000:1:1'),
          const TedMediaIdentity('episode', 'tt4000000:1:2'),
        })
        .then((_) => finished = true);
    // The held production preparation must settle before its rows disappear.
    await cancelled.future;
    expect(finished, false);
    expect(() => manager.beginPlaying(preparedId), throwsA(isA<TedFailure>()));
    client.release.complete();
    await removing;
    await manager.shutdown();
    expect(await manager.queueEntries(), isEmpty);
    expect(await manager.list(), isEmpty);
    expect(client.selections, isEmpty);
  });
  test('season intent persists and deduplicates with a later whole-show request', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-season-queue-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/device.db');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    var store = TedLocalStore(db);
    final client = QueueClient();
    addTearDown(client.auth.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    await login(auth);
    addTearDown(auth.close);
    final manager = TedDownloads(_OwnedQueueClient(auth, client), store, dir, cancelTask: (_) async => true);
    final show = client.data(const TedMediaIdentity('series', 'tt4000000'));
    await seedExistingQueue(manager, show, season: 1);
    await client.entered.future;
    final owner = manager.scope!;
    expect((await store.queuedDownloads(owner)).map((v) => (v['media'] as Map)['id']).toSet(), {
      'tt4000000:1:1',
      'tt4000000:1:2',
    });
    await seedExistingQueue(manager, show, season: 1);
    expect((await store.queuedDownloads(owner)).length, 2);
    await seedExistingQueue(manager, show);
    expect((await store.queuedDownloads(owner)).length, 4);
    final shutdown = manager.shutdown();
    client.release.complete();
    await shutdown;
    manager.dispose();
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    store = TedLocalStore(db);
    addTearDown(db.close);
    expect((await store.queuedDownloads(owner)).length, 4);
    expect(await store.queuedDownloads('$owner-other'), isEmpty);
  });
  test('incomplete season enumeration queues no partial batch and starts no source preparation', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-season-partial-');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final client = IncompleteSeasonQueueClient();
    addTearDown(client.auth.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    await login(auth);
    addTearDown(auth.close);
    final manager = TedDownloads(_OwnedQueueClient(auth, client), store, dir, cancelTask: (_) async => true);
    addTearDown(manager.dispose);
    await expectLater(
      seedExistingQueue(manager, client.data(const TedMediaIdentity('series', 'tt4000000')), season: 1),
      throwsA(isA<TedFailure>()),
    );
    expect(await manager.queueEntries(), isEmpty);
    expect(client.entered.isCompleted, false);
    expect(client.selections, isEmpty);
    await manager.shutdown();
  });
  test('whole-show intent persists before preparation, survives reopen and deduplicates per account', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-show-queue-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/device.db');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    var store = TedLocalStore(db);
    final client = QueueClient();
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    await login(auth);
    addTearDown(auth.close);
    // Reuse real bearer ownership with a controlled adapter at the external boundary.
    final adapter = _OwnedQueueClient(auth, client);
    final manager = TedDownloads(adapter, store, dir, cancelTask: (_) async => true);
    final show = client.data(const TedMediaIdentity('series', 'tt4000000'));
    await seedExistingQueue(manager, show);
    await client.entered.future;
    final owner = manager.scope!;
    expect((await store.queuedDownloads(owner)).length, 4);
    await seedExistingQueue(manager, show);
    expect((await store.queuedDownloads(owner)).length, 4);
    final shutdown = manager.shutdown();
    client.release.complete();
    await shutdown;
    manager.dispose();
    expect(client.selections, isEmpty);
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    store = TedLocalStore(db);
    addTearDown(db.close);
    expect((await store.queuedDownloads(owner)).length, 4);
    expect(await store.queuedDownloads('$owner-other'), isEmpty);
    client.auth.close();
  });
  test('one preparation at a time; mapped failure never selects an addon; siblings use first direct source', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-show-queue-failure-');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final client = QueueClient();
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    await login(auth);
    addTearDown(auth.close);
    addTearDown(client.auth.close);
    final manager = TedDownloads(_OwnedQueueClient(auth, client), store, dir, cancelTask: (_) async => true);
    addTearDown(manager.dispose);
    await seedExistingQueue(manager, client.data(const TedMediaIdentity('series', 'tt4000000')));
    await client.entered.future;
    expect(client.selections, isEmpty);
    client.holdPreparation = false;
    client.release.complete();
    // Observe durable worker transitions, not a fixed wall-clock delay.
    final done = Completer<void>();
    void changed() {
      unawaited(
        manager.queueEntries().then((values) {
          if (values.every((v) => v['status'] == 'failed') && !done.isCompleted) done.complete();
        }),
      );
    }

    manager.addListener(changed);
    changed();
    await done.future.timeout(const Duration(seconds: 10));
    manager.removeListener(changed);
    final values = await manager.queueEntries();
    expect(values.where((v) => v['error'] == 'mapping_not_ready').length, 2);
    expect(client.selections.length, 2);
    expect(
      client.selections.every((v) => v.$1.id.endsWith(':2') && v.$2 == '11111111-1111-4111-8111-111111111111'),
      true,
    );
    await manager.shutdown();
  });
  test('schema 26 upgrade creates queue while preserving device identity and downloads', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-v26-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/device.db');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    await db.customStatement(
      "INSERT INTO ted_installation(key,value) VALUES('device','44444444-4444-4444-8444-444444444444')",
    );
    await db.customStatement("INSERT INTO ted_downloads(id,scope,media,value) VALUES('saved','owner','movie','{}')");
    await db.customStatement('DROP TABLE ted_download_queue');
    await db.customStatement('DROP TABLE ted_season_sources');
    await db.customStatement('DROP TABLE ted_track_languages');
    await db.customStatement('DROP TABLE ted_source_cache');
    await db.customStatement('DROP TABLE ted_home_cache');
 await db.customStatement('ALTER TABLE ted_sessions DROP COLUMN qualified');
 await db.customStatement('DROP TABLE ted_profile_pictures');
 await db.customStatement('PRAGMA user_version=26');
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    expect(
      (await db.customSelect('SELECT value FROM ted_installation').getSingle()).read<String>('value'),
      '44444444-4444-4444-8444-444444444444',
    );
    expect((await db.customSelect('SELECT id FROM ted_downloads').getSingle()).read<String>('id'), 'saved');
    expect(await TedLocalStore(db).queuedDownloads('owner'), isEmpty);
  });
  test('whole-show transfers stay sequential and remove durable intent only after validated publication', () async {
    final dir = await Directory.systemTemp.createTemp('teddy-show-files-');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final etag = '"ted-${'a' * 64}"';
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/resolve')) {
          final id = (jsonDecode(r.body) as Map)['session_id'];
          return response({
            'session_id': id,
            'media_url': '/api/client/v1/downloads/$id/media',
            'etag': etag,
            'bytes': 4,
          });
        }
        return response(pair(DateTime.now()));
      }),
    );
    await login(auth);
    addTearDown(auth.close);
    final fixture = QueueClient();
    addTearDown(fixture.auth.close);
    final client = _SuccessfulQueueClient(auth, fixture);
    final entered = Completer<void>(), release = Completer<void>(), done = Completer<void>();
    var transfers = 0;
    final manager = TedDownloads(
      client,
      store,
      dir,
      cancelTask: (_) async => true,
      transferTask: (task) async {
        transfers++;
        if (transfers == 1) {
          entered.complete();
          await release.future;
        }
        final id = task.taskId.substring('teddy-'.length);
        await File('${dir.path}/$id/chunk').writeAsBytes([1, 2, 3, 4]);
        return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
          'content-range': 'bytes 0-3/4',
          'etag': etag,
        }, 206);
      },
    );
    addTearDown(manager.dispose);
    void changed() {
      unawaited(
        manager.queueEntries().then((v) {
          if (v.isEmpty && !done.isCompleted) done.complete();
        }),
      );
    }

    await seedExistingQueue(
      manager,
      TedTitle.fromJson({
        ...titleData(kind: 'series', id: 'tt4000000'),
        'seasons': [1],
      }),
    );
    await entered.future;
    expect(transfers, 1);
    expect((await manager.list()).length, 1);
    expect((await manager.queueEntries()).length, 2);
    manager.addListener(changed);
    release.complete();
    await done.future.timeout(const Duration(seconds: 10));
    manager.removeListener(changed);
    final files = await manager.list();
    expect(files.length, 2);
    expect(files.every((v) => v['status'] == 'complete'), true);
    for (final file in files) {
      expect(await File('${dir.path}/${file['id']}/media.bin').readAsBytes(), [1, 2, 3, 4]);
    }
    expect(client.selections.map((s) => s.$2), [null, '11111111-1111-4111-8111-111111111111']);
    await manager.shutdown();
  });
}

class _OwnedQueueClient extends TedClient {
  final QueueClient delegate;
  _OwnedQueueClient(super.auth, this.delegate);
  @override
  Future<TedEpisodePage> episodes(String id, int season, {int? after}) => delegate.episodes(id, season, after: after);
  @override
  Future<TedTitle> title(TedMediaIdentity media) => delegate.title(media);
  @override
  Future<TedSourcePage> sources(TedMediaIdentity media, {String? previousSession}) =>
      delegate.sources(media, previousSession: previousSession);
  @override
  Future<TedPlaybackSession> createSession(TedMediaIdentity media, {String? sourceId}) =>
      delegate.createSession(media, sourceId: sourceId);
}

class _SuccessfulQueueClient extends _OwnedQueueClient {
  final selections = <(TedMediaIdentity, String?)>[];
  _SuccessfulQueueClient(super.auth, super.delegate);
  @override
  Future<TedTitle> title(TedMediaIdentity media) async => delegate.data(media);
  @override
  Future<TedSourcePage> sources(TedMediaIdentity media, {String? previousSession}) async =>
      media.id.endsWith(':1') ? const TedSourcePage(true, true, [], [], null) : delegate.sources(media);
  @override
  Future<TedPlaybackSession> createSession(TedMediaIdentity media, {String? sourceId}) async {
    selections.add((media, sourceId));
    return TedPlaybackSession(
      '33333333-3333-4333-8333-33333333333${media.id.split(':').last}',
      media,
      'direct-file',
      100000,
      0,
    );
  }
}
