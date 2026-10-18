import 'dart:async';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show LazyDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_character_names.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_download_button.dart';
import 'package:plezy/ted/ted_download_progress.dart';
import 'package:plezy/ted/ted_downloads.dart';
import 'package:plezy/ted/ted_downloads_screen.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_movie_detail.dart';
import 'package:plezy/ted/ted_series_detail.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/theme/mono_theme.dart';
import '../test_helpers/prefs.dart';
import 'ted_movie_detail_test.dart' show MovieFixture;
import 'ted_series_detail_test.dart' show SeriesDetailFixture;
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_download_tree_test.dart' show file, PresentationDownloads, PresentationStore;

class HeldProjectionDownloads extends TedDownloads {
  final entered = Completer<void>();
  final release = Completer<List<Map<String, dynamic>>>();
  var reads = 0;
  HeldProjectionDownloads(super.client, super.store, super.root)
    : super(
        cancelTask: (_) async => true,
        transferTask: (_) async => throw StateError('Projection fixture must not start native transfers'),
      );
  @override
  Future<List<Map<String, dynamic>>> list() {
    reads++;
    entered.complete();
    return release.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    await SettingsService.getInstance();
    addTearDown(() {
      TvDetectionService.debugReset();
      PlatformDetector.debugSetIsDesktopOSOverride(null);
    });
  });
  test('English character labels keep accented Latin and distinct roles, hide original-script aliases', () {
    expect(tedEnglishCharacterNames(['坂本太郎 / Taro Sakamoto', 'Taro Sakamoto']), 'Taro Sakamoto');
    expect(
      tedEnglishCharacterNames(['Kōhei Nikaidō (二階堂浩平)', 'Lead / Narrator', 'English (voice)']),
      'Kōhei Nikaidō / Lead / Narrator / English (voice)',
    );
    expect(tedEnglishCharacterNames(['山彦']), '');
  });

  test('queue totals deduplicate prepared episodes, isolate seasons and retain paused/failed status', () {
    final a = file('', 1, const TedMediaIdentity('episode', 'tt1234567:1:1'), 'One');
    final b = file('', 2, const TedMediaIdentity('episode', 'tt1234567:1:2'), 'Two')..['status'] = 'downloading';
    final c = file('', 3, const TedMediaIdentity('episode', 'tt1234567:2:1'), 'Three')..['status'] = 'paused';
    final intent = {'media': b['media'], 'status': 'queued'};
    final live = {b['id'] as String: const TedTransferProgress(5, 1250000)};
    const show = TedMediaIdentity('series', 'tt1234567');
    final all = TedDownloadProgress.select([a, b, c], [intent], live, {}, show)!;
    expect(all.total, 3);
    expect(all.label, 'Downloading 2 of 3');
    expect(TedDownloadProgress.select([a, b, c], [intent], live, {}, show, season: 1)!.label, 'Downloading 2 of 2');
    expect(TedDownloadProgress.select([a, b, c], [intent], live, {}, show, season: 2)!.label, 'Paused 0 of 1');
    final episode = TedDownloadProgress.select(
      [b],
      [intent],
      live,
      {},
      const TedMediaIdentity('episode', 'tt1234567:1:2'),
    )!;
    expect(episode.fraction, .5);
    expect(episode.speed, '10.0 Mbps');
    c['status'] = 'failed';
    expect(TedDownloadProgress.select([c], [], {}, {}, show, season: 2)!.label, 'Failed 0 of 1');
    expect(TedDownloadProgress.select([c], [], {}, {}, const TedMediaIdentity('series', 'tt7654321')), isNull);
  });

  test('effective speed spans bursty ranges and synthetic final progress', () {
    final rate = TedDownloadRate(0, Duration.zero);
    final speeds = <double>[];
    const size = 8 * 1024 * 1024;
    // Representative live pattern: each 8 MiB range ramps up, completes,
    // then waits for the next request. It averages about 26 Mbps overall.
    for (var range = 0; range < 8; range++) {
      for (final (milliseconds, fraction) in [
        (600, .001),
        (1100, .03),
        (1600, .15),
        (2100, .5),
        (2540, .999),
        (2541, 1.0),
      ]) {
        final now = Duration(milliseconds: range * 2541 + milliseconds);
        rate.record(range * size + (size * fraction).floor(), now);
        final speed = rate.bytesPerSecond(now);
        if (now.inSeconds >= 5) speeds.add(speed! * 8 / 1000000);
      }
    }
    expect(speeds, everyElement(inInclusiveRange(20, 35)));
  });

  test('speed warms up, decays during stalls and ignores retried/duplicate bytes', () {
    final rate = TedDownloadRate(1000000, Duration.zero);
    rate.record(2000000, const Duration(milliseconds: 250));
    expect(rate.bytesPerSecond(const Duration(milliseconds: 250)), isNull);
    rate.record(5000000, const Duration(seconds: 1));
    expect(rate.bytesPerSecond(const Duration(seconds: 1)), 4000000);
    rate.record(4000000, const Duration(seconds: 2)); // retry before the prior high-water mark
    rate.record(5000000, const Duration(seconds: 3));
    rate.record(6000000, const Duration(milliseconds: 500)); // stale callback
    expect(rate.bytesPerSecond(const Duration(seconds: 4)), 1000000);
    expect(rate.bytesPerSecond(const Duration(seconds: 6)), isNull);
  });

  test('native range handoff retains effective speed and the validated checkpoint', () async {
    final root = await Directory.systemTemp.createTemp('ted-speed-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Speed');
    final store = TedLocalStore(db), scope = tedOfflineScope(auth)!;
    const media = TedMediaIdentity('movie', 'tt1234567'), size = TedDownloads.chunkBytes;
    final saved = file(scope, 1, media, 'Movie')
      ..['status'] = 'paused'
      ..['received'] = 0
      ..['bytes'] = size * 2;
    final entered = Completer<void>(), release = Completer<void>();
    var elapsed = Duration.zero, ranges = 0;
    late void Function(double) report;
    late TedDownloads manager;
    manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      progressClock: () => elapsed,
      cancelTask: (_) async => true,
      progressTransferTask: (task, callback) async {
        if (ranges++ == 0) {
          elapsed = const Duration(seconds: 2);
          callback(.999);
          elapsed = const Duration(milliseconds: 2001);
          callback(1);
          // Use a sparse range fixture, retaining the real production boundary
          // without allocating a 512 MiB Dart list.
          final chunk = await File('${manager.directory(saved['id'] as String).path}/chunk').open(mode: FileMode.write);
          await chunk.truncate(size);
          await chunk.close();
          return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
            'content-range': 'bytes 0-${size - 1}/${size * 2}',
            'etag': saved['etag'] as String,
          }, 206);
        }
        report = callback;
        entered.complete();
        await release.future;
        return TaskStatusUpdate(task, TaskStatus.canceled);
      },
    );
    addTearDown(manager.dispose);
    await store.saveDownload(scope, saved);
    final transfer = manager.resume(saved);
    await entered.future;
    await manager.refreshProgress();
    elapsed = const Duration(milliseconds: 2501);
    report(.0001); // a tiny first packet of the second range must not reset speed
    final live = manager.progress(media)!;
    final expected = (size + (size * .0001).floor()) / 2.501;
    expect(live.bytesPerSecond, closeTo(expected, 1));
    expect(live.received, greaterThan(size));
    expect((await store.downloads(scope)).single['received'], size);
    final pausing = manager.pause(saved['id'] as String);
    release.complete();
    await transfer;
    await pausing;
    await manager.refreshProgress();
    expect(manager.progress(media)!.bytesPerSecond, isNull);
    expect(manager.progress(media)!.received, size);
    await manager.shutdown();
    await store.close();
  });

  test('shutdown settles a held progress read and fences new reads before storage closes', () async {
    final db = AppDatabase.forTesting(LazyDatabase(() async => NativeDatabase.memory()));
    addTearDown(db.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => throw StateError('offline fixture')));
    addTearDown(auth.close);
    final manager = HeldProjectionDownloads(TedClient(auth), TedLocalStore(db), Directory('/private/tmp/no-transfer'));
    addTearDown(manager.dispose);
    final read = manager.refreshProgress();
    await manager.entered.future;
    var closed = false;
    final closing = manager.shutdown().then((_) => closed = true);
    await manager.refreshProgress();
    expect(closed, false);
    manager.release.complete([]);
    await read;
    await closing;
    await manager.refreshProgress();
    expect(closed, true);
    expect(manager.reads, 1);
  });

  test('native display progress is transient, speed expires, pause and late callbacks preserve checkpoints', () async {
    final root = await Directory.systemTemp.createTemp('ted-progress-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Progress');
    final store = TedLocalStore(db), scope = tedOfflineScope(auth)!;
    final saved = file(scope, 1, const TedMediaIdentity('movie', 'tt1234567'), 'Movie')
      ..['status'] = 'paused'
      ..['received'] = 2;
    final entered = Completer<void>(), release = Completer<void>();
    late void Function(double) report;
    late DownloadTask task;
    var elapsed = Duration.zero;
    final manager = TedDownloads(
      TedClient(auth),
      store,
      root,
      progressClock: () => elapsed,
      cancelTask: (_) async => true,
      progressTransferTask: (next, callback) async {
        report = callback;
        task = next;
        entered.complete();
        await release.future;
        return TaskStatusUpdate(task, TaskStatus.canceled);
      },
    );
    addTearDown(manager.dispose);
    await store.saveDownload(scope, saved);
    await manager.directory(saved['id'] as String).create();
    await File('${manager.directory(saved['id'] as String).path}/media.partial').writeAsBytes([1, 2]);
    final transfer = manager.resume(saved);
    await entered.future;
    await manager.refreshProgress();
    elapsed = const Duration(seconds: 1);
    report(.5); // half of this 8-byte range, plus the durable 2-byte prefix
    final displayed = manager.progress(const TedMediaIdentity('movie', 'tt1234567'))!;
    expect(displayed.received, 6);
    expect(displayed.bytesPerSecond, 4);
    expect((await store.downloads(scope)).single['received'], 2);
    report(double.nan);
    report(-1);
    report(2);
    elapsed = const Duration(seconds: 2);
    report(.25);
    expect(manager.progress(const TedMediaIdentity('movie', 'tt1234567'))!.received, 6);
    elapsed = const Duration(seconds: 7);
    expect(manager.progress(const TedMediaIdentity('movie', 'tt1234567'))!.bytesPerSecond, isNull);
    final pause = manager.pause(saved['id'] as String);
    report(1);
    release.complete();
    await transfer;
    await pause;
    await manager.refreshProgress();
    report(1); // callback from the settled transfer cannot revive progress
    final paused = manager.progress(const TedMediaIdentity('movie', 'tt1234567'))!;
    expect(paused.status, 'paused');
    expect(paused.received, 2);
    expect(paused.bytesPerSecond, isNull);
    await manager.shutdown();
    await manager.refreshProgress();
    await store.close();
  });

  testWidgets('folder and detail indicators update, retain progress and show scoped counts', (tester) async {
    final db = AppDatabase.forTesting(LazyDatabase(() async => NativeDatabase.memory()));
    addTearDown(db.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => throw StateError('offline fixture')));
    addTearDown(auth.close);
    final files = [
      file('', 1, const TedMediaIdentity('episode', 'tt1234567:1:1'), 'One'),
      file('', 2, const TedMediaIdentity('episode', 'tt1234567:1:2'), 'Two')
        ..['status'] = 'downloading'
        ..['received'] = 5,
      file('', 3, const TedMediaIdentity('movie', 'tt7654321'), 'Movie')
        ..['status'] = 'downloading'
        ..['received'] = 3,
    ];
    final manager = PresentationDownloads(
      TedClient(auth),
      PresentationStore(db),
      Directory('/private/tmp/no-progress-files'),
      files,
    );
    addTearDown(manager.dispose);
    await manager.refreshProgress();
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: Column(
            children: [
              TedDownloadButton(
                downloads: manager,
                media: const TedMediaIdentity('series', 'tt1234567'),
                label: 'Download series',
              ),
              TedDownloadButton(
                downloads: manager,
                media: const TedMediaIdentity('series', 'tt1234567'),
                season: 1,
                label: 'Download season',
              ),
              TedDownloadButton(
                downloads: manager,
                media: const TedMediaIdentity('episode', 'tt1234567:1:2'),
                label: 'Download',
              ),
              Expanded(child: TedDownloadsScreen(downloads: manager)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Downloading 2 of 2'), findsNWidgets(3));
    expect(find.text('Downloading · 50%'), findsOneWidget);
    expect(find.text('Downloading · 30%'), findsOneWidget);
    await tester.tap(find.text('Zulu show'));
    await tester.pump();
    await tester.tap(find.text('Season 1'));
    await tester.pump();
    expect(find.text('Downloading · 50%'), findsNWidgets(2));
    files[1]['received'] = 8;
    await manager.refreshProgress();
    await tester.pump();
    expect(find.text('Downloading · 80%'), findsNWidgets(2));
    tester.view.physicalSize = const Size(390, 1000);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('movie, episode, show and season pages use their own device download progress', (tester) async {
    tester.view.physicalSize = const Size(1292, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(LazyDatabase(() async => NativeDatabase.memory()));
    addTearDown(db.close);
    for (final type in ['movie', 'episode', 'series', 'season']) {
      final client = type == 'movie' ? MovieFixture() : SeriesDetailFixture();
      addTearDown(client.auth.close);
      final rows = type == 'movie'
          ? [
              file('', 1, const TedMediaIdentity('movie', 'tt4000000'), 'Movie')
                ..['status'] = 'downloading'
                ..['received'] = 5,
            ]
          : [
              file('', 1, const TedMediaIdentity('episode', 'tt4000000:1:1'), 'One'),
              file('', 2, const TedMediaIdentity('episode', 'tt4000000:1:2'), 'Two')
                ..['status'] = 'downloading'
                ..['received'] = 5,
              file('', 3, const TedMediaIdentity('episode', 'tt4000000:2:1'), 'Three')..['status'] = 'paused',
            ];
      final manager = PresentationDownloads(
        client,
        PresentationStore(db),
        Directory('/private/tmp/no-detail-progress-files'),
        rows,
      );
      addTearDown(manager.dispose);
      final show = type == 'movie' ? null : client.data(const TedMediaIdentity('series', 'tt4000000'));
      final Widget detail = switch (type) {
        'movie' => TedMovieDetail(
          client: client,
          downloads: manager,
          initial: client.data(const TedMediaIdentity('movie', 'tt4000000')),
          horizontalInset: 40,
          onClose: () {},
          onSidebar: () {},
          onHeader: () {},
          onPlay: (_, _, _) async {},
          onDownload: (_, _) async {},
        ),
        'episode' => TedEpisodeDetail(
          client: client,
          downloads: manager,
          initial: client.data(const TedMediaIdentity('episode', 'tt4000000:1:2')),
          horizontalInset: 40,
          onClose: () {},
          onSidebar: () {},
          onHeader: () {},
          onPlay: (_, _, _) async {},
          onDownload: (_, _) async {},
        ),
        'series' => TedSeriesDetail(
          client: client,
          downloads: manager,
          initial: show!,
          horizontalInset: 40,
          onClose: () {},
          onSidebar: () {},
          onHeader: () {},
          onSeason: (_) {},
          onPerson: (_, _, _) {},
          onDownload: (_) async {},
        ),
        _ => TedSeasonDetail(
          client: client,
          downloads: manager,
          show: show!,
          season: 1,
          horizontalInset: 40,
          onClose: () {},
          onSidebar: () {},
          onHeader: () {},
          onEpisode: (_) {},
          onDownload: (_, _) async {},
        ),
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: Scaffold(body: detail),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          type == 'series'
              ? 'Downloading 2 of 3'
              : type == 'season'
              ? 'Downloading 2 of 2'
              : 'Downloading · 50%',
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byType(TedDownloadButton), matching: find.byType(LinearProgressIndicator)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
