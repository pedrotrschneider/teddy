import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_downloads.dart';
import 'package:plezy/ted/ted_downloads_screen.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_download_watch.dart';
import 'package:plezy/ted/ted_download_tree.dart';
import 'package:plezy/focus/focusable_wrapper.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/widgets/watched_indicator.dart';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/prefs.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;

const session = '33333333-3333-4333-8333-333333333333';
Map<String, dynamic> file(String scope, int number, TedMediaIdentity media, String name) => {
  'id': '44444444-4444-4444-8444-44444444444$number',
  'scope': scope,
  'media': media.toJson(),
  'session': session,
  'url': '/api/client/v1/downloads/$session/media',
  'etag': '"ted-${'a' * 64}"',
  'bytes': 10,
  'received': 10,
  'status': 'complete',
  'downloaded_at': '2026-10-12T12:00:00Z',
  'metadata': MediaItem.ted(
    id: media.id,
    kind: media.kind == 'movie' ? MediaKind.movie : MediaKind.episode,
    title: name,
    grandparentTitle: 'Zulu show',
    parentIndex: media.kind == 'episode' ? int.parse(media.id.split(':')[1]) : null,
    index: media.kind == 'episode' ? int.parse(media.id.split(':')[2]) : null,
  ).toJson(),
  'images': <String, dynamic>{},
  'subtitles': <dynamic>[],
  'duration_ms': 10000,
  'resume_ms': 0,
  'watch_revision': 0,
  'audio_languages': <String>[],
};

class PresentationStore extends TedLocalStore {
  PresentationStore(super.db);
  @override
  Future<int> pending(String scope) async => 0;
}

class PresentationDownloads extends TedDownloads {
  final List<Map<String, dynamic>> files;
  Set<TedMediaIdentity>? removed;
  Set<TedMediaIdentity>? retried;
  final watches = <TedMediaIdentity, TedDownloadWatch>{};
  PresentationDownloads(super.client, super.store, super.root, this.files)
    : super(
        cancelTask: (_) async => true,
        transferTask: (_) async => throw StateError('Presentation fixture must not start native transfers'),
      );
  @override
  Future<List<Map<String, dynamic>>> list() async => files;
  @override
  Future<List<Map<String, dynamic>>> queueEntries() async => [];
  @override
  Future<void> retryFailed(Set<TedMediaIdentity> media) async {
    retried = media;
  }

  @override
  Future<int> diskBytes(Map<String, dynamic> value) async => 10;
  @override
  Future<void> cacheFolderArtwork(Map<String, dynamic> value) async {}
  @override
  Future<Map<TedMediaIdentity, TedDownloadWatch>> watchStates(List<Map<String, dynamic>> files) async => watches;
  @override
  Future<void> removeSelection(Set<TedMediaIdentity> media) async {
    removed = media;
    files.removeWhere((v) => media.contains(TedMediaIdentity.fromJson(v['media'] as Map<String, dynamic>)));
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });
  test('group removal preflights active playback, totals disk files and retains other seasons and history', () async {
    final root = await Directory.systemTemp.createTemp('ted-tree-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Tree');
    final store = TedLocalStore(db), scope = tedOfflineScope(auth)!;
    final a = file(scope, 1, const TedMediaIdentity('episode', 'tt1234567:1:1'), 'One'),
        b = file(scope, 2, const TedMediaIdentity('episode', 'tt1234567:1:2'), 'Two'),
        c = file(scope, 3, const TedMediaIdentity('episode', 'tt1234567:2:1'), 'Three');
    final manager = TedDownloads(TedClient(auth), store, root, cancelTask: (_) async => true);
    addTearDown(manager.dispose);
    for (final value in [a, b, c]) {
      await store.saveDownload(scope, value);
      await manager.directory(value['id'] as String).create();
      await File('${manager.directory(value['id'] as String).path}/media.bin').writeAsBytes(List.filled(10, 0));
    }
    await File('${manager.directory(a['id'] as String).path}/season.image').writeAsBytes([1, 2, 3]);
    expect(await manager.diskBytes(a), 13);
    final media = {
      const TedMediaIdentity('episode', 'tt1234567:1:1'),
      const TedMediaIdentity('episode', 'tt1234567:1:2'),
    };
    manager.beginPlaying(b['id'] as String);
    await expectLater(
      manager.removeSelection(media),
      throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'download_in_use')),
    );
    expect((await manager.list()).length, 3);
    expect(await File('${manager.directory(a['id'] as String).path}/media.bin').exists(), true);
    manager.endPlaying(b['id'] as String);
    await store.record(
      scope,
      TedPlaybackSession(session, const TedMediaIdentity('episode', 'tt1234567:1:1'), '/device/file', 10000, 0),
      {
        'id': '11111111-1111-4111-8111-111111111111',
        'kind': 'stop',
        'observed_at': '2026-10-12T12:00:00Z',
        'sequence': 1,
        'position_ms': 1000,
      },
      offline: true,
    );
    await manager.removeSelection(media);
    expect((await manager.list()).single['id'], c['id']);
    expect(await store.pending(scope), 1);
    expect(await manager.directory(a['id'] as String).exists(), false);
  });

  testWidgets('download folders sort titles, indent seasons/episodes and play device movies directly', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((_) async => throw StateError('No server playback expected')),
    );
    addTearDown(auth.close);
    final files = [
      file('', 1, const TedMediaIdentity('episode', 'tt1234567:1:1'), 'Episode'),
      file('', 2, const TedMediaIdentity('movie', 'tt7654321'), 'Alpha movie'),
    ];
    final manager = PresentationDownloads(
      TedClient(auth),
      PresentationStore(db),
      Directory('/private/tmp/absent-ted-test-downloads'),
      files,
    );
    addTearDown(manager.dispose);
    final key = GlobalKey<TedDownloadsScreenState>();
    String? played;
    var sidebar = 0, ready = 0;
    tester.view.physicalSize = const Size(1200, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: TedDownloadsScreen(
            key: key,
            downloads: manager,
            embedded: true,
            onPlay: (v) async => played = v['id'] as String,
            onSidebar: () => sidebar++,
            onReady: () => ready++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Initial progress refresh can request another storage read. Each ready
    // notification may retry a pending handoff, but must not move focus itself.
    expect(ready, greaterThan(0));
    expect(key.currentState!.requestFocus(first: true), true);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FocusableWrapper>(
            find.ancestor(of: find.text('Alpha movie'), matching: find.byType(FocusableWrapper)),
          )
          .focusNode!
          .hasFocus,
      true,
    );
    expect(tester.getTopLeft(find.text('Alpha movie')).dy, lessThan(tester.getTopLeft(find.text('Zulu show')).dy));
    await tester.tap(find.text('Alpha movie'));
    await tester.pumpAndSettle();
    expect(played, files[1]['id']);
    await tester.tap(find.text('Zulu show'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Episode')).dx, greaterThan(tester.getTopLeft(find.text('Season 1')).dx));
    for (final title in ['Zulu show', 'Season 1']) {
      final wrapper = tester.widget<FocusableWrapper>(
        find.ancestor(of: find.text(title), matching: find.byType(FocusableWrapper)),
      );
      wrapper.focusNode!.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('Episode'), findsOneWidget); // Left never collapses either folder.
    }
    expect(sidebar, 2);
    key.currentState!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus!.debugLabel, startsWith('delete-'));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Episode')).dx, greaterThan(tester.getTopLeft(find.text('Season 1')).dx));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Delete all downloaded episodes of this series'));
    await tester.pumpAndSettle();
    expect(manager.removed, {const TedMediaIdentity('episode', 'tt1234567:1:1')});
    expect(find.text('Zulu show'), findsNothing);
    expect(find.text('Alpha movie'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('download badges count only complete device episodes, separate seasons and reset on re-download', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => throw StateError('offline')));
    addTearDown(auth.close);
    final values = [
      file('', 1, const TedMediaIdentity('episode', 'tt1234567:1:1'), 'One'),
      file('', 2, const TedMediaIdentity('episode', 'tt1234567:1:2'), 'Two'),
      file('', 3, const TedMediaIdentity('episode', 'tt1234567:2:1'), 'Three'),
      file('', 4, const TedMediaIdentity('episode', 'tt1234567:1:3'), 'Pending')..['status'] = 'downloading',
    ];
    final manager = PresentationDownloads(
      TedClient(auth),
      PresentationStore(db),
      Directory('/private/tmp/none'),
      values,
    );
    addTearDown(manager.dispose);
    final at = DateTime.utc(2026, 10, 12, 13);
    final watches = {
      for (final value in values)
        TedMediaIdentity.fromJson(value['media'] as Map<String, dynamic>): TedDownloadWatch(
          TedMediaIdentity.fromJson(value['media'] as Map<String, dynamic>),
          true,
          false,
          0,
          10000,
          at,
          at,
        ),
    };
    var show = tedDownloadTree(manager, values, [], {}, watches: watches).single;
    expect((show.indicatorItem.leafCount, show.indicatorItem.viewedLeafCount, show.watched), (3, 3, true));
    expect(show.children.first.downloaded, 2);
    values[0]['downloaded_at'] = '2026-10-12T14:00:00Z';
    show = tedDownloadTree(manager, values, [], {}, watches: watches).single;
    expect((show.downloaded, show.completed, show.watched), (3, 2, false));
    expect(show.children.first.indicatorItem.unwatchedCount, 1);
    expect(show.children.last.watched, true);
    values.removeAt(1);
    show = tedDownloadTree(manager, values, [], {}, watches: watches).single;
    expect((show.downloaded, show.completed), (2, 1));
  });

  testWidgets('completed movies/episodes share watched and progress artwork indicators', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => throw StateError('offline')));
    addTearDown(auth.close);
    const movie = TedMediaIdentity('movie', 'tt1234567');
    final manager = PresentationDownloads(TedClient(auth), PresentationStore(db), Directory('/private/tmp/none'), [
      file('', 1, movie, 'Movie'),
    ]);
    addTearDown(manager.dispose);
    final at = DateTime.utc(2026, 10, 12, 13);
    manager.watches[movie] = TedDownloadWatch(movie, true, false, 0, 10000, at, at);
    final key = GlobalKey<TedDownloadsScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: TedDownloadsScreen(key: key, downloads: manager),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<WatchedIndicator>(find.byType(WatchedIndicator)).item.isWatched, true);
    manager.watches[movie] = TedDownloadWatch(movie, true, true, 2000, 10000, at, at.subtract(const Duration(days: 1)));
    await key.currentState!.reload();
    await tester.pumpAndSettle();
    final item = tester.widget<WatchedIndicator>(find.byType(WatchedIndicator)).item;
    expect(item.isWatched, false);
    expect(item.viewOffsetMs, 2000);
    expect(item.hasActiveProgress, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed show and season cards expose keyboard-accessible retry and source-change actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((_) async => throw StateError('No playback expected')),
    );
    addTearDown(auth.close);
    const first = TedMediaIdentity('episode', 'tt1234567:1:1'), second = TedMediaIdentity('episode', 'tt1234567:1:2');
    final manager = PresentationDownloads(TedClient(auth), PresentationStore(db), Directory('/private/tmp/none'), [
      {...file('', 1, first, 'First'), 'status': 'failed', 'received': 0},
      file('', 2, second, 'Second'),
    ]);
    addTearDown(manager.dispose);
    final key = GlobalKey<TedDownloadsScreenState>();
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: TedDownloadsScreen(key: key, downloads: manager),
        ),
      ),
    );
    await tester.pumpAndSettle();
    key.currentState!.requestFocus();
    await tester.pump();
    expect(find.byKey(const ValueKey('download-retry-tt1234567')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-source-tt1234567')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final retry = tester.widget<TextButton>(find.byKey(const ValueKey('download-retry-tt1234567')));
    expect(retry.focusNode?.hasFocus, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(manager.retried, {first, second});
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('download-retry-tt1234567:1')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-source-tt1234567:1')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
