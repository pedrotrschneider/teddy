import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_movie_detail.dart';
import 'package:plezy/ted/ted_series_detail.dart';
import 'package:plezy/ted/ted_series_models.dart';
import 'package:plezy/ted/ted_player_screen.dart';
import 'package:plezy/ted/ted_episode_navigation.dart';
import 'package:plezy/ted/ted_play_button.dart';
import 'package:plezy/ted/ted_focus_region.dart';
import '../test_helpers/mock_player_channels.dart';
import 'ted_playback_test.dart' show ControlFixture, sessionId, mediaPath;
import 'package:plezy/widgets/cast_member_strip.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import '../test_helpers/prefs.dart';
import 'ted_catalog_test.dart' show titleData;
import 'ted_home_banner_test.dart' show pixel;
import 'ted_metadata_client_test.dart' show metadataData;
import 'ted_movie_detail_test.dart' show MovieFixture;
import 'ted_keyboard_navigation_test.dart' show focused;

class SeriesDetailFixture extends MovieFixture {
  final watchedChanges = <bool>[];
  final episodeReads = <TedMediaIdentity>[];
  int seasonReads = 0;
  bool showPlayed = false;
  final seasonPlayed = <int, bool>{};
  final seasonChanges = <(int, bool)>[];
  bool failSeasonWatch = false;
  bool coldSummaries = false;
  Completer<TedMetadataSnapshot>? heldSeason;
  TedMetadataSnapshot snapshot(String type) => TedMetadataSnapshot.fromJson({
    ...metadataData(),
    'item': {
      'Id': metadataData()['item']['Id'],
      'Type': type,
      'Name': type == 'Episode' ? 'Specific episode' : 'Show logo title',
      'Overview': type == 'Episode' ? 'Only this episode description' : 'Show description',
      'People': [
        if (type != 'Season')
          {
            'Id': '55555555-5555-4555-8555-555555555555',
            'Name': type == 'Episode' ? 'Guest performer' : 'Show performer',
            'Type': 'Actor',
            'Role': 'Character',
          },
      ],
    },
  });
  @override
  TedTitle data(TedMediaIdentity media) {
    final episode = media.kind == 'episode';
    final tuple = media.id.split(':');
    return TedTitle.fromJson({
      ...titleData(kind: media.kind, id: media.id, ready: episode, played: showPlayed),
      'metadata': {
        'name': 'The show',
        'description': 'Show description',
        if (episode) 'series': {'name': 'The show'},
        if (episode)
          'episode': {'season': int.parse(tuple[1]), 'number': int.parse(tuple[2]), 'name': 'Episode ${tuple[2]}'},
      },
      if (episode) 'parent': {'kind': 'series', 'id': tuple.first},
      'enrichment': {
        'item': {
          'Id': snapshot(episode ? 'Episode' : 'Series').id,
          'Type': episode ? 'Episode' : 'Series',
          'Name': episode ? 'Specific episode' : 'The show',
          'Overview': episode ? 'Only this episode description' : 'Show description',
          'People': [
            {
              'Id': '55555555-5555-4555-8555-555555555555',
              'Name': episode ? 'Guest performer' : 'Show performer',
              'Type': 'Actor',
              'Role': 'Character',
            },
          ],
        },
        'status': 'ready',
        'generation': 1,
        'images': [],
      },
    });
  }

  @override
  Future<TedTitle> title(TedMediaIdentity media) async {
    if (media.kind == 'episode') episodeReads.add(media);
    return data(media);
  }

  @override
  Future<TedSeriesWatch> showWatch(String id) async => TedSeriesWatch('a' * 64, 2, showPlayed ? 2 : 0);
  @override
  Future<void> setShowWatched(String id, String version, bool watched) async {
    watchedChanges.add(watched);
    showPlayed = watched;
  }

  @override
  Future<TedSeriesWatch> seasonWatch(String id, int season) async {
    if (failSeasonWatch) throw const TedFailure('unavailable');
    return TedSeriesWatch('b' * 64, 2, (seasonPlayed[season] ?? showPlayed) ? 2 : 0);
  }

  @override
  Future<void> setSeasonWatched(String id, int season, String version, bool watched) async {
    expect(version, 'b' * 64);
    seasonChanges.add((season, watched));
    seasonPlayed[season] = watched;
  }

  @override
  Future<TedMetadataSnapshot> season(String id, int season) async {
    seasonReads++;
    return heldSeason?.future ?? snapshot('Season');
  }

  @override
  Future<TedEpisodePage> episodes(String id, int season, {int? after}) async => TedEpisodePage(
    [
      for (var i = 1; i <= 2; i++)
        coldSummaries
            ? TedTitle.fromJson({
                ...titleData(kind: 'episode', id: '$id:$season:$i', ready: false),
                'metadata': {
                  'episode': {'name': 'Episode $i', 'season': season, 'number': i},
                  'series': {'name': 'The show'},
                },
              })
            : data(TedMediaIdentity('episode', '$id:$season:$i')),
    ],
    null,
    enrichment: snapshot('Season'),
  );
  @override
  Future<Uint8List?> metadataImage(String id) async => pixel;
  @override
  Future<Uint8List?> personPortrait(String id) async => pixel;
  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async => [
    TedHomeRow('popular-series', [data(const TedMediaIdentity('series', 'tt4000000'))], false, []),
  ];
}

class PagedSeasonFixture extends SeriesDetailFixture {
  Completer<TedEpisodePage>? heldPage;
  int moreReads = 0;
  @override
  Future<TedEpisodePage> episodes(String id, int season, {int? after}) async {
    if (after != null) {
      moreReads++;
      if (heldPage != null) return heldPage!.future;
    }
    return TedEpisodePage(
      [
        for (var i = (after ?? 0) + 1; i <= ((after ?? 0) == 0 ? 50 : 70); i++)
          data(TedMediaIdentity('episode', '$id:$season:$i')),
      ],
      after == null ? 50 : null,
      enrichment: snapshot('Season'),
    );
  }
}

class HomeEpisodeFixture extends SeriesDetailFixture {
  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async => [
    TedHomeRow('continue-watching', [data(const TedMediaIdentity('episode', 'tt4000000:1:1'))], false, []),
    TedHomeRow('next-up', [data(const TedMediaIdentity('episode', 'tt4000000:1:2'))], false, []),
  ];
}

class EpisodeCastFixture extends SeriesDetailFixture {
  bool queued = true;
  bool emptyCast = false;
  final ready = Completer<TedMetadataSnapshot>();
  @override
  TedTitle data(TedMediaIdentity media) {
    final title = super.data(media);
    if (media.kind != 'episode') return title;
    final original = title.enrichment!;
    return title.withEnrichment(
      TedMetadataSnapshot(
        id: original.id,
        status: queued ? 'queued' : 'ready',
        generation: original.generation,
        name: original.name,
        overview: original.overview,
        type: original.type,
        images: [],
        people: queued || emptyCast ? [] : original.people,
      ),
    );
  }

  @override
  Future<TedMetadataSnapshot> metadata(String id) {
    metadataReads++;
    return ready.future;
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader('Go Noto Current')..addFont(rootBundle.load('assets/go-noto-current-regular.ttf'))).load();
  });
  setUp(() async {
    resetSharedPreferencesForTest();
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    await SettingsService.getInstance();
    (await TvDetectionService.getInstance()).setForceTv(true);
    addTearDown(() {
      TvDetectionService.debugReset();
      PlatformDetector.debugSetIsDesktopOSOverride(null);
    });
  });
  Future<void> mount(
    WidgetTester tester,
    Widget child,
    SeriesDetailFixture client, {
    Size size = const Size(1920, 1080),
    bool settleReady = true,
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.auth.close);
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          key: UniqueKey(),
          theme: monoTheme(dark: true),
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: Scaffold(body: child),
        ),
      ),
    );
    if (settleReady) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('Shows entry retains season navigation, controls and sidebar through the full Back flow', (tester) async {
    final client = SeriesDetailFixture();
    var downloads = 0;
    final seasonDownloads = <int>[];
    await mount(
      tester,
      TedBrowseScreen(
        client: client,
        onPlay: (_) async {},
        onDownloadShow: (_) async {
          downloads++;
        },
        onDownloadSeason: (_, season) async => seasonDownloads.add(season),
      ),
      client,
    );
    await tester.tap(
      find.byWidgetPredicate((w) => w is NavigationRailItem && w.label is Text && (w.label as Text).data == 'Shows'),
    );
    await tester.pumpAndSettle();
    final showCard = find
        .byWidgetPredicate((w) => w is MediaCard && (w.item as MediaItem).id == 'series/tt4000000')
        .first;
    await tester.ensureVisible(showCard);
    await tester.tap(showCard);
    await tester.pumpAndSettle();
    expect(find.byType(TedSeriesDetail), findsOneWidget);
    expect(find.byType(NavigationRailItem), findsNWidgets(8));
    expect(find.text('Next Up'), findsNothing);
    expect(find.text('Start from the beginning'), findsNothing);
    await tester.tap(find.text('Download show'));
    await tester.pumpAndSettle();
    expect(downloads, 1);
    await tester.tap(find.text('Mark show watched'));
    await tester.pumpAndSettle();
    expect(client.watchedChanges, [true]);
    expect(find.text('Mark show unwatched'), findsOneWidget);
    final seasonCard = find.byWidgetPredicate(
      (w) => w is MediaCard && (w.item as MediaItem).id == 'season/tt4000000/1',
    );
    await tester.ensureVisible(seasonCard);
    await tester.tap(seasonCard);
    await tester.pumpAndSettle();
    expect(find.byType(TedSeasonDetail), findsOneWidget);
    expect(find.text('Season 1 Episode 1'), findsOneWidget);
    await tester.tap(find.text('Download season'));
    await tester.pumpAndSettle();
    expect(seasonDownloads, [1]);
    final epCard = find.byWidgetPredicate((w) => w is MediaCard && (w.item as MediaItem).id == 'episode/tt4000000:1:1');
    await tester.tap(epCard);
    await tester.pumpAndSettle();
    expect(find.byType(TedEpisodeDetail), findsOneWidget);
    expect(find.byType(NavigationRailItem), findsNWidgets(8));
    expect(find.text('Only this episode description'), findsOneWidget);
    expect(find.text('Guest performer'), findsNothing);
    expect(find.text('Show performer'), findsOneWidget);
    expect(client.sourceReads, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TedSeasonDetail), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TedSeriesDetail), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TedSeriesDetail), findsNothing);
    expect(focused(showCard), true);
    final showsNav = find.byWidgetPredicate(
      (w) => w is NavigationRailItem && w.label is Text && (w.label as Text).data == 'Shows',
    );
    expect(tester.widget<NavigationRailItem>(showsNav).isSelected, true);
    expect(tester.takeException(), isNull);
  });
  testWidgets('season summaries do not fetch full episode details; thumbnails use the wide caption layout', (
    tester,
  ) async {
    final client = SeriesDetailFixture()..coldSummaries = true;
    await mount(
      tester,
      TedSeasonDetail(
        client: client,
        show: client.data(const TedMediaIdentity('series', 'tt4000000')),
        season: 1,
        horizontalInset: 36,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onEpisode: (_) {},
      ),
      client,
    );
    expect(client.episodeReads, isEmpty);
    final card = find.byWidgetPredicate((w) => w is MediaCard && (w.item as MediaItem).id == 'episode/tt4000000:1:1');
    final rect = tester.getRect(card);
    expect(rect.width / rect.height, greaterThan(1));
    expect(find.text('Season 1 Episode 2'), findsOneWidget);
    expect(find.text('Episode 1'), findsOneWidget);
    expect(find.text('Episode 2'), findsOneWidget);
    final name = find.descendant(of: card, matching: find.text('Episode 1'));
    final numbering = find.descendant(of: card, matching: find.text('Season 1 Episode 1'));
    expect(tester.getRect(name).bottom, lessThanOrEqualTo(tester.getRect(numbering).top));
    expect(tester.widget<Text>(name).style!.fontSize, greaterThan(tester.widget<Text>(numbering).style!.fontSize!));
    expect(tester.takeException(), isNull);
  });
  testWidgets('season actions use season state, preserve episode selection and form a keyboard lane', (tester) async {
    final client = SeriesDetailFixture()
      ..showPlayed = true
      ..seasonPlayed[1] = false;
    final downloaded = <int>[];
    var back = 0, sidebar = 0;
    await mount(
      tester,
      TedSeasonDetail(
        client: client,
        show: client.data(const TedMediaIdentity('series', 'tt4000000')),
        season: 1,
        horizontalInset: 36,
        onClose: () => back++,
        onSidebar: () => sidebar++,
        onHeader: () {},
        onEpisode: (_) {},
        onDownload: (show, season) async {
          expect(show.media.id, 'tt4000000');
          downloaded.add(season);
        },
      ),
      client,
    );
    expect(find.text('Mark season watched'), findsOneWidget); // whole show was played
    final second = find.byWidgetPredicate((w) => w is MediaCard && (w.item as MediaItem).id == 'episode/tt4000000:1:2');
    tester.state<HubSectionState>(find.byType(HubSection)).requestFocusAt(1);
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<SingleChildScrollView>(
          find.descendant(of: find.byType(TedSeasonDetail), matching: find.byType(SingleChildScrollView)).first,
        )
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focused(find.text('Download season')), true);
    expect(scroll.offset, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focused(find.text('Mark season watched')), true);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.seasonChanges, [(1, true)]);
    expect(find.text('Mark season unwatched'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused(second), true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focused(find.text('Mark season unwatched')), true);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.seasonChanges, [(1, true), (1, false)]);
    await tester.tap(find.text('Download season'));
    await tester.pumpAndSettle();
    expect(downloaded, [1]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(focused(find.text('Download season')), true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(sidebar, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(back, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('season focus reveals complete episode cards with a margin at TV viewport sizes', (tester) async {
    for (final size in [const Size(960, 540), const Size(1280, 720), const Size(1920, 1080)]) {
      final client = SeriesDetailFixture();
      await mount(
        tester,
        TedSeasonDetail(
          client: client,
          show: client.data(const TedMediaIdentity('series', 'tt4000000')),
          season: 1,
          horizontalInset: 36,
          onClose: () {},
          onSidebar: () {},
          onHeader: () {},
          onEpisode: (_) {},
        ),
        client,
        size: size,
      );
      final hub = find.byType(HubSection);
      final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first).controller!;
      expect(tester.getRect(hub).bottom, lessThanOrEqualTo(size.height - 7));
      expect(tester.getRect(hub).top, greaterThanOrEqualTo(8));
      final revealed = scroll.offset;
      // Returning from lower content restores the most hero that still fits
      // the whole shelf; horizontal traversal keeps this same vertical offset.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      tester.state<HubSectionState>(hub).requestFocusAt(1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(revealed, .01));
      expect(tester.getRect(hub).bottom, lessThanOrEqualTo(size.height - 7));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a deferred episode reveal cannot scroll after switching to pointer input', (tester) async {
    final client = SeriesDetailFixture();
    await mount(
      tester,
      TedSeasonDetail(
        client: client,
        show: client.data(const TedMediaIdentity('series', 'tt4000000')),
        season: 1,
        horizontalInset: 36,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onEpisode: (_) {},
      ),
      client,
      size: const Size(960, 540),
    );
    final hub = tester.state<HubSectionState>(find.byType(HubSection));
    final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first).controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    hub.requestFocusAt(1);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.moveTo(const Offset(20, 20));
    final before = scroll.offset;
    await tester.pumpAndSettle();
    expect(InputModeTracker.currentMode, InputMode.pointer);
    expect(scroll.offset, before);
    await mouse.removePointer();
  });

  testWidgets('show and season pointer hover or pointer focus never reveals the banner; keyboard focus does', (
    tester,
  ) async {
    for (final tv in [false, true]) {
      (await TvDetectionService.getInstance()).setForceTv(tv);
      for (final season in [false, true]) {
        final client = SeriesDetailFixture();
        final title = client.data(const TedMediaIdentity('series', 'tt4000000'));
        await mount(
          tester,
          season
              ? TedSeasonDetail(
                  client: client,
                  show: title,
                  season: 1,
                  horizontalInset: 36,
                  onClose: () {},
                  onSidebar: () {},
                  onHeader: () {},
                  onEpisode: (_) {},
                  onDownload: (_, _) async {},
                )
              : TedSeriesDetail(
                  client: client,
                  initial: title,
                  horizontalInset: 36,
                  onClose: () {},
                  onSidebar: () {},
                  onHeader: () {},
                  onSeason: (_) {},
                  onPerson: (_, _, _) {},
                  onDownload: (_) async {},
                ),
          client,
          size: const Size(1512, 950),
        );
        final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first).controller!;
        expect(scroll.position.maxScrollExtent, greaterThan(80));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(10, 10));
        final before = FocusManager.instance.primaryFocus;
        for (final label in [
          season ? 'Download season' : 'Download show',
          season ? 'Mark season watched' : 'Mark show watched',
        ]) {
          await mouse.moveTo(const Offset(10, 10));
          scroll.jumpTo(80);
          await tester.pump();
          await mouse.moveTo(tester.getCenter(find.text(label)));
          await tester.pumpAndSettle();
          expect(scroll.offset, closeTo(80, .01));
          expect(FocusManager.instance.primaryFocus, same(before));
        }
        final actions = tester.state<TedFocusRegionState>(find.byType(TedFocusRegion).first);
        actions.requestFocus(first: true);
        await tester.pumpAndSettle();
        expect(scroll.offset, closeTo(80, .01), reason: 'Pointer-mode programmatic focus is not navigation');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(scroll.offset, closeTo(0, .01));
        expect(client.watchedChanges, isEmpty);
        expect(client.seasonChanges, isEmpty);
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
      }
    }
  });
  testWidgets('failed season state disables only watch editing; retry restores the season toggle', (tester) async {
    final client = SeriesDetailFixture()..failSeasonWatch = true;
    await mount(
      tester,
      TedSeasonDetail(
        client: client,
        show: client.data(const TedMediaIdentity('series', 'tt4000000')),
        season: 1,
        horizontalInset: 12,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onEpisode: (_) {},
        onDownload: (_, _) async {},
      ),
      client,
      size: const Size(600, 800),
    );
    final watched = find.widgetWithText(OutlinedButton, 'Mark season watched');
    expect(tester.widget<OutlinedButton>(watched).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Download season')).onPressed, isNotNull);
    expect(find.text('Season 1 Episode 1'), findsOneWidget);
    client.failSeasonWatch = false;
    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(watched).onPressed, isNotNull);
    expect(find.text('Retry'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('episode banner and controls remain usable in a narrow window', (tester) async {
    final client = SeriesDetailFixture();
    await mount(
      tester,
      TedEpisodeDetail(
        client: client,
        initial: client.data(const TedMediaIdentity('episode', 'tt4000000:1:1')),
        horizontalInset: 12,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onPlay: (_, _, _) async {},
      ),
      client,
      size: const Size(390, 844),
    );
    await tester.ensureVisible(find.text('Start from the beginning'));
    expect(find.text('Only this episode description'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('return refresh keeps loaded episode pages and the exact deep selection', (tester) async {
    final client = PagedSeasonFixture();
    final key = GlobalKey<TedSeasonDetailState>();
    await mount(
      tester,
      TedSeasonDetail(
        key: key,
        client: client,
        show: client.data(const TedMediaIdentity('series', 'tt4000000')),
        season: 1,
        horizontalInset: 36,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onEpisode: (_) {},
      ),
      client,
    );
    final shelf = find.byType(HubSection);
    final hub = tester.state<HubSectionState>(shelf);
    expect(tester.widget<HubSection>(shelf).hub.items.length, 50);
    hub.requestFocusAt(49);
    await tester.pumpAndSettle();
    expect(tester.widget<HubSection>(shelf).hub.items.length, 70);
    hub.requestFocusAt(59);
    await tester.pumpAndSettle();
    final refresh = key.currentState!.reload();
    await tester.pumpAndSettle();
    await refresh;
    await tester.pumpAndSettle();
    key.currentState!.requestFocus();
    await tester.pumpAndSettle();
    expect(tester.widget<HubSection>(shelf).hub.items.length, 70);
    final card = find.byWidgetPredicate((w) => w is MediaCard && (w.item as MediaItem).id == 'episode/tt4000000:1:60');
    expect(focused(card), true);
    expect(tester.takeException(), isNull);
  });
  testWidgets('return refresh fences a held older page and permits fresh pagination', (tester) async {
    final client = PagedSeasonFixture()..heldPage = Completer<TedEpisodePage>();
    final key = GlobalKey<TedSeasonDetailState>();
    await mount(
      tester,
      TedSeasonDetail(
        key: key,
        client: client,
        show: client.data(const TedMediaIdentity('series', 'tt4000000')),
        season: 1,
        horizontalInset: 36,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onEpisode: (_) {},
      ),
      client,
    );
    final shelf = find.byType(HubSection);
    final hub = tester.state<HubSectionState>(shelf);
    hub.requestFocusAt(49);
    // The intentionally held page keeps its progress indicator animating.
    // Advance the focus/scroll frames without waiting for that request to end.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(client.moreReads, 1);
    final reload = key.currentState!.reload();
    await tester.pumpAndSettle();
    await reload;
    await tester.pumpAndSettle();
    // Return to the start, then physically scroll back to the paging boundary.
    // Moving between the last two visible cards need not move the viewport.
    hub.requestFocusAt(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    hub.requestFocusAt(49);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(client.moreReads, greaterThan(1));
    client.heldPage!.complete(
      TedEpisodePage([for (var i = 51; i <= 70; i++) client.data(TedMediaIdentity('episode', 'tt4000000:1:$i'))], null),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<HubSection>(shelf).hub.items.length, 70);
    expect(tester.takeException(), isNull);
  });

  testWidgets('show opens with complete season cards visible; season focus restores the banner', (tester) async {
    for (final (height, tv) in const [
      (1080.0, true),
      (900.0, true),
      (720.0, true),
      (1080.0, false),
      (900.0, false),
      (720.0, false),
    ]) {
      (await TvDetectionService.getInstance()).setForceTv(tv);
      final client = SeriesDetailFixture();
      final key = GlobalKey<TedSeriesDetailState>();
      await mount(
        tester,
        TedSeriesDetail(
          key: key,
          client: client,
          initial: client.data(const TedMediaIdentity('series', 'tt4000000')),
          horizontalInset: 36,
          onClose: () {},
          onSidebar: () {},
          onHeader: () {},
          onSeason: (_) {},
          onPerson: (_, _, _) {},
        ),
        client,
        size: Size(1920, height),
      );
      final hub = tester.state<HubSectionState>(find.byType(HubSection));
      expect(tester.widget<HubSection>(find.byType(HubSection)).hub.items.map((item) => item.index), [1, 0]);
      final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first).controller!;
      expect(scroll.offset, closeTo(0, .01));
      expect(tester.getRect(find.byType(MediaCard).first).bottom, lessThan(height - 6));
      hub.requestFocusAt(0);
      await tester.pumpAndSettle();
      final card = find.byType(MediaCard).first;
      expect(tester.getRect(card).bottom, lessThan(height - 6));
      // Focus retains the existing shelf-bottom margin, which may reveal a
      // little extra empty Hub padding even though the cards already fit.
      final focusedOffset = scroll.offset;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      hub.requestFocusAt(1);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(MediaCard).last).bottom, lessThan(height - 6));
      expect(scroll.offset, closeTo(focusedOffset, .01));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(0, .01));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('season poster doubles and episode artwork grows within the banner', (tester) async {
    final client = SeriesDetailFixture();
    await mount(
      tester,
      TedSeasonDetail(
        client: client,
        show: client.data(const TedMediaIdentity('series', 'tt4000000')),
        season: 1,
        horizontalInset: 36,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onEpisode: (_) {},
      ),
      client,
    );
    var art = tester.getRect(find.byKey(const ValueKey('ted-detail-leading-artwork')));
    expect(art.width, closeTo(340, .01));
    expect(art.height, closeTo(510, .01));
    expect(art.top, greaterThan(80));
    await mount(
      tester,
      TedEpisodeDetail(
        client: client,
        initial: client.data(const TedMediaIdentity('episode', 'tt4000000:1:1')),
        horizontalInset: 36,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onPlay: (_, _, _) async {},
      ),
      client,
    );
    art = tester.getRect(find.byKey(const ValueKey('ted-detail-leading-artwork')));
    expect(art.width, closeTo(540, .01));
    expect(art.width / art.height, closeTo(16 / 9, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home episode entries return through season and show, retaining the original shelf', (tester) async {
    for (final row in ['continue-watching', 'next-up']) {
      final client = HomeEpisodeFixture();
      await mount(tester, TedBrowseScreen(client: client, onPlay: (_) async {}), client);
      final hub = tester.state<HubSectionState>(
        find.descendant(of: find.byKey(ValueKey(row)), matching: find.byType(HubSection)),
      );
      hub.requestFocusAt(0);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(TedEpisodeDetail), findsOneWidget);
      expect(find.byType(TedSeasonDetail, skipOffstage: false), findsNothing);
      expect(find.byType(TedSeriesDetail, skipOffstage: false), findsNothing);
      expect(client.seasonReads, 0);
      final episode = row == 'continue-watching' ? 1 : 2;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TedSeasonDetail), findsOneWidget);
      final card = find.byWidgetPredicate(
        (w) => w is MediaCard && (w.item as MediaItem).id == 'episode/tt4000000:1:$episode',
      );
      expect(focused(card), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TedSeriesDetail), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TedSeriesDetail), findsNothing);
      expect(focused(find.byKey(ValueKey(row))), true);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'Escape from the real player restores details and remains usable through every parent with no leaf focus',
    (tester) async {
      await initializeDateFormatting('en');
      LocaleSettings.setLocaleSync(AppLocale.en);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final name in ['window_manager', 'com.plezy/macos_window', 'com.plezy/window_utils']) {
        final channel = MethodChannel(name);
        messenger.setMockMethodCallHandler(channel, (call) async => false);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }
      final client = HomeEpisodeFixture();
      final f = ControlFixture();
      final navigator = GlobalKey<NavigatorState>();
      await f.auth.login('https://ted.example', 'fixture', '', 'Back flow fixture');
      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        methodHandler: f.method,
        testBody: () async {
          try {
            await mount(
              tester,
              TedBrowseScreen(
                client: client,
                onPlay: (_) async {},
                onPlaySelection: (title, _, _) async {
                  await navigator.currentState!.push<TedPlayerExit>(
                    MaterialPageRoute(
                      builder: (_) => TeddyPlayer(
                        client: TedClient(f.auth),
                        player: f.player,
                        title: title.name,
                        session: TedPlaybackSession(
                          sessionId,
                          title.media,
                          mediaPath,
                          100000,
                          0,
                          originalLanguage: 'ja',
                        ),
                      ),
                    ),
                  );
                },
              ),
              client,
              navigatorKey: navigator,
            );
            final hub = tester.state<HubSectionState>(
              find.descendant(of: find.byKey(const ValueKey('continue-watching')), matching: find.byType(HubSection)),
            );
            hub.requestFocusAt(0);
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            await tester.tap(find.byType(TedPlayButton));
            await tester.pumpAndSettle();
            expect(find.byType(TeddyPlayer), findsOneWidget);
            f.player.handlePlayerEvent('file-loaded', null);
            f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 0.0});
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.byType(TeddyPlayer), findsNothing);
            expect(find.byType(TedEpisodeDetail), findsOneWidget);
            expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));
            // Losing the leaf focus again must not disable page Back.
            FocusManager.instance.primaryFocus!.unfocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.byType(TedSeasonDetail), findsOneWidget);
            FocusManager.instance.primaryFocus!.unfocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.byType(TedSeriesDetail), findsOneWidget);
            FocusManager.instance.primaryFocus!.unfocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.byType(TedSeriesDetail), findsNothing);
            expect(f.reports.last['natural_eof'], false);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            await tester.runAsync(() => f.player.dispose());
            f.auth.close();
          }
        },
      );
    },
  );

  testWidgets('direct episode return loads its season page through the selected deep episode', (tester) async {
    final client = PagedSeasonFixture();
    await mount(
      tester,
      TedSeasonDetail(
        client: client,
        show: client.data(const TedMediaIdentity('series', 'tt4000000')),
        season: 1,
        initialEpisode: const TedMediaIdentity('episode', 'tt4000000:1:60'),
        horizontalInset: 36,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onEpisode: (_) {},
      ),
      client,
    );
    expect(tester.widget<HubSection>(find.byType(HubSection)).hub.items.length, 70);
    final card = find.byWidgetPredicate((w) => w is MediaCard && (w.item as MediaItem).id == 'episode/tt4000000:1:60');
    expect(focused(card), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('episode description enrichment preserves the show cast even without episode credits', (tester) async {
    final client = EpisodeCastFixture();
    await mount(
      tester,
      TedEpisodeDetail(
        client: client,
        initial: client.data(const TedMediaIdentity('episode', 'tt4000000:1:1')),
        horizontalInset: 36,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onPlay: (_, _, _) async {},
      ),
      client,
      settleReady: false,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(client.metadataReads, 1);
    expect(find.text('Show performer'), findsOneWidget);
    client.queued = false;
    client.ready.complete(client.data(const TedMediaIdentity('episode', 'tt4000000:1:1')).enrichment!);
    await tester.pumpAndSettle();
    expect(find.byType(CastMemberStrip), findsOneWidget);
    expect(find.text('Guest performer'), findsNothing);
    expect(find.text('Show performer'), findsOneWidget);
    expect(client.metadataReads, 1);
    final empty = EpisodeCastFixture()
      ..queued = false
      ..emptyCast = true;
    await mount(
      tester,
      TedEpisodeDetail(
        client: empty,
        initial: empty.data(const TedMediaIdentity('episode', 'tt4000000:1:1')),
        horizontalInset: 36,
        onClose: () {},
        onSidebar: () {},
        onHeader: () {},
        onPlay: (_, _, _) async {},
      ),
      empty,
    );
    expect(find.text('Cast'), findsOneWidget);
    expect(find.byType(CastMemberStrip), findsOneWidget);
    expect(find.text('Show performer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
