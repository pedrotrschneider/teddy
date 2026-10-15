import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_bulk_downloads.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_download_plan.dart';
import 'package:plezy/ted/ted_downloads.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_source_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

const showId = 'tt4000000';
const oldSession = '33333333-3333-4333-8333-333333333333';
const newSession = '33333333-3333-4333-8333-333333333334';
const savedId = '44444444-4444-4444-8444-444444444444';
String hash(int n) => n.toRadixString(16).padLeft(64, '0');
TedSourceChoice choice(int n, {int group = 1, int addon = 1, int handle = 1}) => TedSourceChoice(
  '11111111-1111-4111-8111-${(n * 100 + handle).toString().padLeft(12, '0')}',
  'Fixture add-on',
  'Pack $group',
  'Episode $n',
  addonId: hash(addon),
  sourceKey: hash(n),
  bingeKey: group < 0 ? '' : hash(group),
);
TedTitle episode(int n, {bool watched = false, int season = 1, int position = 0}) => TedTitle(
  TedMediaIdentity('episode', '$showId:$season:$n'),
  'Show · S$season E$n',
  '',
  watched,
  0,
  position,
  false,
  seriesName: 'Show',
  episodeName: 'Episode $n',
  parent: const TedMediaIdentity('series', showId),
  season: season,
  episode: n,
);
const show = TedTitle(TedMediaIdentity('series', showId), 'Show', '', false, 0, 0, false, seasons: [1]);
TedSourcePage addonPage(List<TedSourceChoice> choices) => TedSourcePage(false, false, choices, [], null);

class BulkClient extends TedClient {
  final titles = <TedTitle>[for (var n = 1; n <= 4; n++) episode(n)];
  final mapped = <String>{'$showId:1:1', '$showId:1:2'};
  final streams = <String, List<TedSourceChoice>>{
    for (var n = 1; n <= 4; n++) '$showId:1:$n': [choice(n)],
  };
  final lookups = <(String, String)>[], sessions = <(TedMediaIdentity, String?)>[];
  Completer<void>? titleGate, sourceGate;
  bool rejectSessions = false;
  BulkClient(super.auth);
  @override
  Future<List<TedTitle>> allEpisodes(TedTitle show, {int? season}) async =>
      titles.where((v) => season == null || v.season == season).toList();
  @override
  Future<TedTitle> title(TedMediaIdentity media) async {
    await titleGate?.future;
    return titles.firstWhere((v) => v.media == media);
  }

  @override
  Future<TedSourcePage> mappedSource(TedMediaIdentity media) async {
    lookups.add(('mapped', media.id));
    return TedSourcePage(
      mapped.contains(media.id),
      mapped.contains(media.id),
      [],
      [],
      null,
      mappedFileName: mapped.contains(media.id) ? 'episode.mkv' : '',
    );
  }

  @override
  Future<TedSourcePage> stremioSources(
    TedMediaIdentity media, {
    bool forceRefresh = false,
    String preferredAddonId = '',
    Future<void>? abortTrigger,
  }) async {
    lookups.add(('stremio', media.id));
    await sourceGate?.future;
    return addonPage(streams[media.id] ?? []);
  }

  @override
  Future<TedPlaybackSession> createSession(TedMediaIdentity media, {String? sourceId}) async {
    sessions.add((media, sourceId));
    if (rejectSessions) throw const TedFailure('source_selection_required');
    return TedPlaybackSession(
      newSession,
      media,
      '/api/client/v1/playback/$newSession/media',
      10000,
      0,
      source: sourceId == null ? 'mapped_rd' : 'addon',
      addonId: sourceId == null ? '' : hash(1),
      bingeKey: sourceId == null ? '' : hash(1),
      originalLanguage: 'en',
    );
  }
}

class BulkHarness {
  final Directory dir;
  AppDatabase db;
  TedLocalStore store;
  final BulkClient client;
  late TedDownloads downloads;
  int transfers = 0;
  Completer<void>? transferGate;
  BulkHarness(this.dir, this.db, this.store, this.client);
  static Future<BulkHarness> create({bool holdWorker = true, File? database}) async {
    final dir = await Directory.systemTemp.createTemp('teddy-bulk-');
    final db = AppDatabase.forTesting(database == null ? NativeDatabase.memory() : NativeDatabase(database));
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/resolve')) {
          final session = (jsonDecode(request.body) as Map)['session_id'];
          return response({
            'session_id': session,
            'media_url': '/api/client/v1/downloads/$session/media',
            'etag': '"ted-${hash(10)}"',
            'bytes': 4,
          });
        }
        return response(pair(DateTime.now()));
      }),
    );
    await auth.login('https://ted.example', 'fixture', '', 'Bulk fixture');
    final client = BulkClient(auth);
    if (holdWorker) client.titleGate = Completer<void>();
    final h = BulkHarness(dir, db, TedLocalStore(db), client);
    h.downloads = TedDownloads(
      client,
      h.store,
      dir,
      cancelTask: (_) async => true,
      transferTask: (task) async {
        h.transfers++;
        await h.transferGate?.future;
        await File(await task.filePath()).writeAsBytes([1, 2, 3, 4]);
        return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
          'content-range': 'bytes 0-3/4',
          'etag': '"ted-${hash(10)}"',
        }, 206);
      },
    );
    await h.store.queuedDownloads(h.downloads.scope!);
    return h;
  }

  Future<void> close() async {
    for (final gate in [client.titleGate, client.sourceGate, transferGate]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await downloads.shutdown();
    downloads.dispose();
    client.auth.close();
    await db.close();
    await dir.delete(recursive: true);
  }

  Map<String, dynamic> saved(TedTitle title, {String status = 'failed', String session = oldSession}) => {
    'id': savedId,
    'scope': downloads.scope,
    'media': title.media.toJson(),
    'session': session,
    'url': '/api/client/v1/downloads/$session/media',
    'etag': '"ted-${hash(10)}"',
    'bytes': 4,
    'received': 2,
    'status': status,
    'metadata': MediaItem.ted(
      id: title.media.id,
      kind: MediaKind.episode,
      title: title.episodeName,
      grandparentTitle: 'Show',
      parentIndex: 1,
      index: 1,
    ).toJson(),
    'images': <String, dynamic>{},
    'subtitles': <dynamic>[],
    'duration_ms': 10000,
    'resume_ms': 0,
    'watch_revision': 0,
    'audio_languages': <String>[],
    'original_language': 'en',
  };
}

Future<void> present(WidgetTester tester, BulkHarness h, {Set<TedMediaIdentity>? failed}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    InputModeTracker(
      child: MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(chooseTedBulkDownloads(context, h.downloads, show: show, failed: failed)),
              child: const Text('Open bulk'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open bulk'));
  await tester.pump();
}

Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    // SQLite uses real asynchronous callbacks; advance that boundary as well
    // as Flutter's simulated frame clock, without extending the deadline.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done(), true, reason: tester.widgetList<Text>(find.byType(Text)).map((v) => v.data).join(' | '));
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> closeWidgetHarness(WidgetTester tester, BulkHarness h) async {
  // Queue futures belong to the widget's fake zone. Settle those with frames;
  // only the actual database/filesystem teardown belongs to runAsync.
  for (final gate in [h.client.titleGate, h.client.sourceGate, h.transferGate]) {
    if (gate != null && !gate.isCompleted) gate.complete();
  }
  var stopped = false;
  final stopping = h.downloads.shutdown().then((_) => stopped = true);
  await until(tester, () => stopped);
  await stopping;
  h.downloads.dispose();
  h.client.auth.close();
  await tester.runAsync(() async {
    await h.db.close();
    await h.dir.delete(recursive: true);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });
  test('binge matching is unique and add-on scoped; mapped matching never falls through automatically', () async {
    final h = await BulkHarness.create();
    addTearDown(h.close);
    final mapped = await tedBulkSourceOptions(h.client, episode(2).media, const TedDownloadSource.mapped());
    expect(mapped.automatic?.provider, 'mapped');
    expect(h.client.lookups, [('mapped', '$showId:1:2')]);
    final missing = await tedBulkSourceOptions(h.client, episode(3).media, const TedDownloadSource.mapped());
    expect(missing.automatic, isNull);
    expect(missing.page.choices, isNotEmpty);
    final previous = TedDownloadSource.choice(choice(1));
    final matching = await tedBulkSourceOptions(h.client, episode(3).media, previous);
    expect(matching.automatic?.sourceKey, hash(3));
    h.client.streams[episode(3).media.id] = [choice(3), choice(33)];
    expect((await tedBulkSourceOptions(h.client, episode(3).media, previous)).automatic, isNull);
    h.client.streams[episode(3).media.id] = [choice(3, addon: 2)];
    expect((await tedBulkSourceOptions(h.client, episode(3).media, previous)).automatic, isNull);
    expect(
      TedDownloadSource.choice(choice(1, group: -1)).match(addonPage([choice(2, group: -1)]), nextEpisode: true),
      isNull,
    );
  });
  testWidgets('all plans RD then a new binge group without transferring before the final selection', (tester) async {
    final h = (await tester.runAsync(() => BulkHarness.create()))!;
    addTearDown(() => closeWidgetHarness(tester, h));
    await present(tester, h);
    await tester.tap(find.text('Download all'));
    await until(tester, () => find.text('RD mapped source').evaluate().isNotEmpty);
    expect(await h.downloads.queueEntries(), isEmpty);
    await tester.tap(find.text('RD mapped source'));
    await until(
      tester,
      () => find.textContaining('S1 E3').evaluate().isNotEmpty && find.text('Pack 1').evaluate().isNotEmpty,
    );
    expect(await h.downloads.queueEntries(), isEmpty);
    expect(h.transfers, 0);
    await tester.tap(find.text('Pack 1'));
    await until(tester, () => find.text('Cancel').evaluate().isEmpty);
    final queue = await h.downloads.queueEntries();
    expect(queue.map((v) => (v['media'] as Map)['id']), [for (var n = 1; n <= 4; n++) '$showId:1:$n']);
    expect(queue.map((v) => (v['selected_source'] as Map)['provider']), ['mapped', 'mapped', 'stremio', 'stremio']);
    expect((queue[3]['selected_source'] as Map)['source_key'], hash(4));
    expect(h.transfers, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Escape midway discards all staged choices and leaves no durable intents', (tester) async {
    final h = (await tester.runAsync(() => BulkHarness.create()))!;
    addTearDown(() => closeWidgetHarness(tester, h));
    await present(tester, h);
    await tester.tap(find.text('Download all'));
    await until(tester, () => find.text('RD mapped source').evaluate().isNotEmpty);
    await tester.tap(find.text('RD mapped source'));
    await until(
      tester,
      () => find.textContaining('S1 E3').evaluate().isNotEmpty && find.text('Pack 1').evaluate().isNotEmpty,
    );
    await press(tester, LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await h.downloads.queueEntries(), isEmpty);
    expect(await h.downloads.list(), isEmpty);
    expect(h.client.sessions, isEmpty);
    expect(h.transfers, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'unwatched includes started episodes; Skip episode advances and Skip remaining commits only chosen items',
    (tester) async {
      final h = (await tester.runAsync(() => BulkHarness.create()))!;
      addTearDown(() => closeWidgetHarness(tester, h));
      h.client.mapped.clear();
      h.client.titles[0] = episode(1, watched: true);
      h.client.titles[1] = episode(2, position: 1000);
      h.client.streams[episode(3).media.id] = [choice(3, group: -1)];
      await present(tester, h);
      await tester.tap(find.text('Download unwatched'));
      await until(
        tester,
        () => find.textContaining('S1 E2').evaluate().isNotEmpty && find.text('Pack 1').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Skip episode'));
      await until(tester, () => find.text('Pack -1').evaluate().isNotEmpty);
      await tester.tap(find.text('Pack -1'));
      await until(
        tester,
        () => find.textContaining('S1 E4').evaluate().isNotEmpty && find.text('Skip remaining').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Skip remaining'));
      await until(tester, () => find.text('Cancel').evaluate().isEmpty);
      expect((await h.downloads.queueEntries()).map((v) => (v['media'] as Map)['id']), ['$showId:1:3']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Cancel during held lookup fences its late response and footer keys stay logical', (tester) async {
    final h = (await tester.runAsync(() => BulkHarness.create()))!;
    addTearDown(() => closeWidgetHarness(tester, h));
    h.client.sourceGate = Completer<void>();
    await present(tester, h);
    await tester.tap(find.text('Download all'));
    await until(tester, () => find.text('Matching sources…').evaluate().isNotEmpty);
    await tester.tap(find.text('Cancel'));
    h.client.sourceGate!.complete();
    await tester.pumpAndSettle();
    expect(await h.downloads.queueEntries(), isEmpty);
    h.client.sourceGate = null;
    h.client.streams.clear();
    await tester.tap(find.text('Open bulk'));
    await tester.pump();
    await tester.tap(find.text('Download all'));
    await until(tester, () => find.text('RD mapped source').evaluate().isNotEmpty);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus?.context?.widget, isNotNull);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Reload')).focusNode?.hasFocus, true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Skip episode')).focusNode?.hasFocus, true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('RD mapped source'), findsNothing);
    expect(await h.downloads.queueEntries(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  test('complete-plan persistence rolls back on a later failed write and fences another account', () async {
    final h = await BulkHarness.create();
    addTearDown(h.close);
    final candidates = await h.downloads.downloadCandidates(h.client.titles);
    await h.db.customStatement(
      "CREATE TRIGGER reject_bulk BEFORE INSERT ON ted_download_queue WHEN NEW.media LIKE '%:2%' BEGIN SELECT RAISE(ABORT,'controlled failure'); END",
    );
    final plan = [for (final candidate in candidates) TedPlannedDownload(candidate, const TedDownloadSource.mapped())];
    await expectLater(
      h.downloads.enqueuePlan(h.downloads.scope!, plan),
      throwsA(predicate((e) => e.toString().contains('controlled failure'))),
    );
    expect(await h.downloads.queueEntries(), isEmpty);
    expect(h.client.sessions, isEmpty);
    await expectLater(h.downloads.enqueuePlan('other-account', plan), throwsA(isA<TedFailure>()));
  });
  test('prepared source lookup renews the exact chosen release rather than a matching pack variant', () async {
    final h = await BulkHarness.create(holdWorker: false);
    addTearDown(h.close);
    h.client.mapped.clear();
    final candidate = (await h.downloads.downloadCandidates([episode(1)])).single;
    final selected = TedDownloadSource.choice(choice(1));
    h.client.streams[episode(1).media.id] = [choice(99)]; // same group, another stable release
    await h.downloads.enqueuePlan(h.downloads.scope!, [TedPlannedDownload(candidate, selected)]);
    await waitQueue(h, () => h.downloads.queueEntries(), (v) => v.single['status'] == 'failed');
    expect((await h.downloads.queueEntries()).single['error'], 'source_selection_required');
    expect(h.client.sessions, isEmpty);
    expect(h.transfers, 0);
  });
  test('failed source preparation preserves owned bytes; retry retains the newly selected source', () async {
    final h = await BulkHarness.create(holdWorker: false);
    addTearDown(h.close);
    h.client.rejectSessions = true;
    final old = h.saved(episode(1));
    await h.store.saveDownload(h.downloads.scope!, old);
    final dir = h.downloads.directory(savedId);
    await dir.create();
    await File('${dir.path}/media.partial').writeAsBytes([9, 9]);
    final candidate = (await h.downloads.failedCandidates({episode(1).media})).single;
    await h.downloads.enqueuePlan(h.downloads.scope!, [
      TedPlannedDownload(candidate, TedDownloadSource.choice(choice(1))),
    ]);
    await waitQueue(h, () => h.downloads.queueEntries(), (v) => v.single['status'] == 'failed');
    expect(await File('${dir.path}/media.partial').readAsBytes(), [9, 9]);
    expect((await h.downloads.list()).single['session'], oldSession);
    h.client.rejectSessions = false;
    h.client.streams[episode(1).media.id] = [choice(1, handle: 2)];
    await h.downloads.retryFailed({episode(1).media});
    await waitQueue(h, () => h.downloads.list(), (v) => v.single['status'] == 'complete');
    expect(h.client.sessions.last.$2, choice(1, handle: 2).id);
    expect(await File('${dir.path}/media.bin').readAsBytes(), [1, 2, 3, 4]);
    expect((await h.downloads.list()).single['session'], newSession);
  });

  test('retry groups target failed episodes only and candidates preserve completed and active siblings', () async {
    final h = await BulkHarness.create();
    addTearDown(h.close);
    h.transferGate = Completer<void>();
    final first = episode(1), second = episode(2), third = episode(1, season: 2);
    final failed = {...h.saved(first), 'received': 0};
    final complete = {
      ...h.saved(second, status: 'complete'),
      'id': '44444444-4444-4444-8444-444444444445',
      'received': 4,
      'downloaded_at': '2026-10-01T12:00:00Z',
    };
    await h.store.saveDownload(h.downloads.scope!, failed);
    await h.store.saveDownload(h.downloads.scope!, complete);
    final queue = [
      {
        'id': '55555555-5555-4555-8555-555555555551',
        'scope': h.downloads.scope,
        'media': first.media.toJson(),
        'name': first.name,
        'status': 'paused',
        'metadata': failed['metadata'],
      },
      for (final title in [episode(3), third])
        {
          'id': title.season == 2 ? '55555555-5555-4555-8555-555555555552' : '55555555-5555-4555-8555-555555555553',
          'scope': h.downloads.scope,
          'media': title.media.toJson(),
          'name': title.name,
          'status': 'failed',
          'metadata': MediaItem.ted(
            id: title.media.id,
            kind: MediaKind.episode,
            title: title.episodeName,
            grandparentTitle: 'Show',
          ).toJson(),
          'selected_source': const TedDownloadSource.mapped().toJson(),
        },
    ];
    await h.store.enqueueDownloads(h.downloads.scope!, queue);
    final scopeSelection = {first.media, second.media, episode(3).media};
    expect(await h.downloads.failedDownloads(scopeSelection), {first.media, episode(3).media});
    final candidates = await h.downloads.failedCandidates(scopeSelection);
    expect(candidates.map((c) => c.title.media), [first.media, episode(3).media]);
    await h.downloads.retryFailed(scopeSelection);
    final entries = await h.downloads.queueEntries();
    expect(entries.where((v) => v['status'] == 'queued').map((v) => (v['media'] as Map)['id']).toSet(), {
      first.media.id,
      episode(3).media.id,
    });
    expect(entries.singleWhere((v) => (v['media'] as Map)['id'] == third.media.id)['status'], 'failed');
    expect((await h.downloads.list()).singleWhere((v) => v['id'] == complete['id'])['status'], 'complete');
  });

  test('source change rejects a completed replacement target without deleting its files', () async {
    final h = await BulkHarness.create();
    addTearDown(h.close);
    final old = h.saved(episode(1));
    await h.store.saveDownload(h.downloads.scope!, old);
    final candidate = (await h.downloads.failedCandidates({episode(1).media})).single;
    final dir = h.downloads.directory(savedId);
    await dir.create();
    await File('${dir.path}/media.bin').writeAsBytes([5, 5, 5, 5]);
    await h.store.saveDownload(h.downloads.scope!, {
      ...old,
      'status': 'complete',
      'received': 4,
      'downloaded_at': '2026-10-13T12:00:00Z',
    });
    await expectLater(
      h.downloads.enqueuePlan(h.downloads.scope!, [TedPlannedDownload(candidate, const TedDownloadSource.mapped())]),
      throwsA(isA<TedFailure>()),
    );
    expect(await h.downloads.queueEntries(), isEmpty);
    expect(await File('${dir.path}/media.bin').readAsBytes(), [5, 5, 5, 5]);
    expect((await h.downloads.list()).single['session'], oldSession);
  });

  test('reopened SQLite resumes a journaled source change after failed bytes were reset', () async {
    final databaseDir = await Directory.systemTemp.createTemp('teddy-bulk-reopen-');
    addTearDown(() => databaseDir.delete(recursive: true));
    final database = File('${databaseDir.path}/state.sqlite');
    final h = await BulkHarness.create(holdWorker: false, database: database);
    addTearDown(h.close);
    final owner = h.downloads.scope!;
    await h.store.saveDownload(owner, h.saved(episode(1)));
    final prepared = {...h.saved(episode(1), status: 'paused', session: newSession), 'received': 0};
    await h.store.enqueueDownloads(owner, [
      {
        'id': '55555555-5555-4555-8555-555555555555',
        'scope': owner,
        'media': episode(1).media.toJson(),
        'name': 'Show · S1 E1',
        'status': 'queued',
        'selected_source': TedDownloadSource.choice(choice(1)).toJson(),
        'replace_download': {'id': savedId, 'session': oldSession},
        'replacement': prepared,
      },
    ]);
    await h.downloads.shutdown();
    h.downloads.dispose();
    await h.db.close();
    h.db = AppDatabase.forTesting(NativeDatabase(database));
    h.store = TedLocalStore(h.db);
    h.client.rejectSessions = true; // Recovery must use the prepared descriptor.
    h.downloads = TedDownloads(
      h.client,
      h.store,
      h.dir,
      cancelTask: (_) async => true,
      transferTask: (task) async {
        await File(await task.filePath()).writeAsBytes([1, 2, 3, 4]);
        return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
          'content-range': 'bytes 0-3/4',
          'etag': '"ted-${hash(10)}"',
        }, 206);
      },
    );
    expect((await h.downloads.queueEntries()).single['replacement'], isNotNull);
    h.downloads.pumpQueue();
    await waitQueue(h, () => h.downloads.list(), (v) => v.single['status'] == 'complete');
    expect(h.client.sessions, isEmpty);
    expect(h.client.lookups, isEmpty);
    expect((await h.downloads.list()).single['session'], newSession);
    expect(await File('${h.downloads.directory(savedId).path}/media.bin').readAsBytes(), [1, 2, 3, 4]);
  });
}

Future<void> waitQueue(
  BulkHarness h,
  Future<List<Map<String, dynamic>>> Function() read,
  bool Function(List<Map<String, dynamic>>) done,
) async {
  final settled = Completer<void>();
  void changed() {
    unawaited(
      read().then((rows) {
        if (rows.isNotEmpty && done(rows) && !settled.isCompleted) settled.complete();
      }),
    );
  }

  h.downloads.addListener(changed);
  changed();
  try {
    await settled.future.timeout(const Duration(seconds: 10));
  } finally {
    h.downloads.removeListener(changed);
  }
}
