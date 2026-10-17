import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_browse_header.dart';
import 'package:plezy/ted/ted_home_banner.dart';
import 'package:plezy/ted/ted_movie_detail.dart';
import 'package:plezy/ted/ted_play_button.dart';
import 'package:plezy/ted/ted_source_models.dart';
import 'package:plezy/ted/teddy_settings_screen.dart';
import 'package:plezy/ted/ted_series_detail.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import '../test_helpers/prefs.dart';
import 'ted_browse_test.dart' show BrowseFixture;
import 'ted_catalog_test.dart' show titleData;

class KeyboardFixture extends BrowseFixture {
  bool empty = false, failHome = false;
  List<TedTitle>? continued;
  List<TedHomeRow>? homeRows;
  Completer<List<TedHomeRow>>? heldHome;
  List<TedTitle> get movies => List.generate(
    7,
    (i) => TedTitle.fromJson({
      ...titleData(id: 'tt${1000000 + i}'),
      'metadata': {'name': 'Movie $i'},
    }),
  );
  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async {
    if (failHome) throw const TedFailure('catalog_unavailable');
    if (homeRows != null) return homeRows!;
    if (heldHome != null) return heldHome!.future;
    return empty
        ? []
        : [
            TedHomeRow('continue-watching', continued ?? movies.take(3).toList(), false, []),
            TedHomeRow('next-up', movies.skip(3).take(2).toList(), false, []),
            TedHomeRow('popular-movie', movies, false, []),
            TedHomeRow('popular-series', [show], false, []),
          ];
  }

  @override
  Future<TedCatalogPage> browse(
    String kind, {
    int skip = 0,
    String catalog = 'popular',
    String? search,
    String genre = '',
    bool mapped = false,
    String watched = 'all',
    String? after,
  }) async {
    pages.add(skip);
    if (search?.isNotEmpty == true) queries.add('$kind:$search');
    return TedCatalogPage(skip == 0 ? movies : [movie], skip == 0 ? 50 : null);
  }

  @override
  Future<TedTitle> title(TedMediaIdentity media) async => media.kind == 'series'
      ? show
      : media.kind == 'episode'
      ? TedTitle.fromJson(titleData(kind: 'episode', id: media.id, ready: false, played: played))
      : movies.firstWhere((t) => t.media == media, orElse: () => movie);
  @override
  Future<TedPersonalPage> personal(String row, {String? after}) async => TedPersonalPage(movies, null, []);
}

class PlayableKeyboardFixture extends KeyboardFixture {
  @override
  Future<TedSourcePage> mappedSource(TedMediaIdentity media) async => const TedSourcePage(true, true, [], [], null);
}

class SidebarFixture extends KeyboardFixture {
  final reads = <String>[];
  Completer<TedCatalogPage>? heldMovie, heldShow;
  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) {
    reads.add('home');
    return super.home();
  }

  @override
  Future<TedCatalogPage> browse(
    String kind, {
    int skip = 0,
    String catalog = 'popular',
    String? search,
    String genre = '',
    bool mapped = false,
    String watched = 'all',
    String? after,
  }) {
    reads.add(kind);
    return (search == null ? (kind == 'movie' ? heldMovie : heldShow) : null)?.future ??
        super.browse(
          kind,
          skip: skip,
          catalog: catalog,
          search: search,
          genre: genre,
          mapped: mapped,
          watched: watched,
          after: after,
        );
  }

  @override
  Future<TedMappedPage> mappedTitles({String? after}) async {
    reads.add('mapped');
    return TedMappedPage(movies, null);
  }
}

bool focused(Finder finder) {
  final targets = finder.evaluate().toSet();
  final node = FocusManager.instance.primaryFocus;
  if (node is FocusScopeNode) return false;
  final context = node?.context;
  if (context is! Element) return false;
  if (targets.contains(context)) return true;
  var found = false;
  for (final target in targets) {
    target.visitAncestorElements((element) {
      if (element == context) found = true;
      return !found;
    });
  }
  context.visitAncestorElements((element) {
    if (targets.contains(element)) found = true;
    return !found;
  });
  return found;
}

Finder card(int i) => find.byWidgetPredicate(
  (widget) => widget is MediaCard && (widget.item as MediaItem).id == 'movie/tt${1000000 + i}',
);

void main() {
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

  Future<void> settle(WidgetTester tester) async {
    final play = find.descendant(of: find.byType(TedPlayButton), matching: find.byType(FilledButton));
    final deadline = tester.binding.clock.fromNowBy(const Duration(minutes: 10));
    do {
      await tester.pump(const Duration(milliseconds: 100));
      if (focused(play)) {
        // Readiness may focus Play during a frame. Its deliberate repeating
        // pulse cannot settle; only finish the bounded navigation transition.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        return;
      }
      if (tester.binding.clock.now().isAfter(deadline)) fail('Navigation did not settle');
    } while (tester.binding.hasScheduledFrame);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  Future<void> mount(
    WidgetTester tester,
    KeyboardFixture client, {
    bool tv = true,
    double width = 1200,
    double height = 900,
    String displayName = 'Tester',
    VoidCallback? onSettings,
    onSignOut,
    Future<void> Function(TedTitle)? play,
  }) async {
    TvDetectionService.debugReset();
    await TvDetectionService.getInstance(forceTv: tv);
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.auth.close);
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          key: UniqueKey(),
          theme: monoTheme(dark: true),
          home: Scaffold(
            body: TedBrowseScreen(
              client: client,
              onPlay: play ?? (_) async {},
              displayName: displayName,
              onSettings: onSettings,
              onSignOut: onSignOut,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  NavigationRailItem rail(WidgetTester tester, int i) =>
      tester.widgetList<NavigationRailItem>(find.byType(NavigationRailItem)).elementAt([1, 2, 3, 0][i]);
  final primary = find.descendant(of: find.byType(TedHomeBanner), matching: find.byType(FilledButton));
  final details = find.descendant(of: find.byType(TedHomeBanner), matching: find.byType(OutlinedButton));

  Finder shelf(String id) => find.byWidgetPredicate((widget) => widget is HubSection && widget.hub.id == id);
  int shelfIndex(WidgetTester tester, Finder finder) {
    final widget = tester.widget<HubSection>(finder);
    final key = widget.hub.serverId == null ? widget.hub.id : '${widget.hub.serverId}:${widget.hub.id}';
    return widget.focusMemory.getForHubOnly(key, widget.hub.items.length);
  }

  testWidgets('sidebar arrows stay in the sidebar and Right enters the active view on desktop and TV', (tester) async {
    for (final tv in [false, true]) {
      await mount(tester, KeyboardFixture(), tv: tv);
      expect(rail(tester, 0).focusNode.hasPrimaryFocus, true);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(tv ? find.byKey(const ValueKey('continue-watching')) : primary), true);
      expect(rail(tester, 0).isSelected, true);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(rail(tester, 0).focusNode.hasPrimaryFocus, true);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(rail(tester, 3).focusNode.hasPrimaryFocus, true);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(rail(tester, 3).focusNode.hasPrimaryFocus, true);
      expect(rail(tester, 0).isSelected, true);
      await press(tester, LogicalKeyboardKey.enter);
      expect(rail(tester, 3).isSelected, true);
      expect(focused(find.byType(TextField)), true);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(find.byType(MediaCard).evaluate().any((element) => focused(find.byWidget(element.widget))), true);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(find.byType(TextField)), true);
      await press(tester, LogicalKeyboardKey.escape);
      if (tv) {
        // The first TV back dismisses the native keyboard.
        expect(focused(find.byType(TextField)), true);
        await press(tester, LogicalKeyboardKey.escape);
      }
      expect(rail(tester, 3).focusNode.hasPrimaryFocus, true);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('sidebar arrow focus preserves the active section and only Enter opens another view', (tester) async {
    for (final tv in [false, true]) {
      final client = SidebarFixture();
      await mount(tester, client, tv: tv);
      await press(tester, LogicalKeyboardKey.arrowUp);
      const labels = ['Search', 'Home', 'Movies', 'Shows', 'Downloads'];
      NavigationRailItem item(int i) => tester
          .widgetList<NavigationRailItem>(find.byType(NavigationRailItem))
          .firstWhere((v) => (v.label as Text).data == labels[i]);
      for (var i = 1; i < labels.length; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(item(i).focusNode.hasPrimaryFocus, true);
        expect(item(1).isSelected, true);
      }
      expect(client.reads, ['home'], reason: 'Focus must not send catalog requests');
      for (var i = labels.length - 2; i >= 0; i--) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(item(0).focusNode.hasPrimaryFocus, true);
      expect(item(1).isSelected, true);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(
        focused(tv ? find.byKey(const ValueKey('continue-watching')) : primary),
        true,
        reason: 'Right enters Home even while Search is focused',
      );
      await press(tester, LogicalKeyboardKey.escape);
      expect(item(1).focusNode.hasPrimaryFocus, true);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(item(2).isSelected, true);
      expect(focused(card(0)), true);
      expect(client.reads, ['home', 'movie']);
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.enter);
      expect(client.reads, ['home', 'movie'], reason: 'Enter on the active section does not reload');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('rapid sidebar changes fence late catalogue success and failure while preserving current focus', (
    tester,
  ) async {
    for (final tv in [false, true]) {
      final client = SidebarFixture()
        ..heldMovie = Completer<TedCatalogPage>()
        ..heldShow = Completer<TedCatalogPage>();
      await mount(tester, client, tv: tv);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(client.reads.last, 'movie');
      expect(rail(tester, 1).isSelected, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(client.reads.last, 'series');
      expect(rail(tester, 2).isSelected, true);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        await tester.pump();
      }
      expect(rail(tester, 3).focusNode.hasPrimaryFocus, true);
      expect(rail(tester, 2).isSelected, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      client.heldMovie!.complete(const TedCatalogPage([], null));
      client.heldShow!.completeError(const TedFailure('catalog_unavailable'));
      await settle(tester);
      expect(rail(tester, 3).isSelected, true);
      expect(focused(find.byType(TextField)), true);
      expect(find.descendant(of: find.byType(TedBrowseHeader), matching: find.byType(Text)), findsNothing);
      expect(find.byType(MediaCard), findsWidgets);
      expect(find.text(const TedFailure('catalog_unavailable').message), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('returning to the active sidebar item and its boundary does not reload the view', (tester) async {
    for (final tv in [false, true]) {
      final client = SidebarFixture();
      await mount(tester, client, tv: tv);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(client.reads.where((section) => section == 'movie').length, 1);
      expect(find.byType(MediaCard).evaluate().any((element) => focused(find.byWidget(element.widget))), true);
      await press(tester, LogicalKeyboardKey.escape);
      expect(rail(tester, 1).focusNode.hasPrimaryFocus, true);
      expect(client.reads.where((section) => section == 'movie').length, 1);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowUp);
      final count = client.reads.length;
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(rail(tester, 3).focusNode.hasPrimaryFocus, true);
      expect(client.reads.length, count);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('held Left stops at the first Home card until a fresh press exits to the sidebar', (tester) async {
    for (final tv in [false, true]) {
      await mount(tester, KeyboardFixture(), tv: tv);
      await press(tester, LogicalKeyboardKey.arrowRight);
      final movies = shelf('popular-movie');
      final hub = tester.state<HubSectionState>(movies);
      hub.requestFocusAt(5);
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(shelfIndex(tester, movies), 4);
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
        await settle(tester);
      }
      expect(hub.hasFocus, true);
      expect(shelfIndex(tester, movies), 0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(hub.hasFocus, true, reason: 'Releasing Left does not leave the shelf');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(rail(tester, 0).focusNode.hasPrimaryFocus, true);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(hub.hasFocus, true);
      expect(shelfIndex(tester, movies), 0);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('TV catalogue shelves and filters clamp held Left and leave on the next press', (tester) async {
    for (final section in [1, 2]) {
      await mount(tester, SidebarFixture());
      for (var i = 0; i < section; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      await press(tester, LogicalKeyboardKey.enter);
      final titles = shelf(section == 1 ? 'popular-movie' : 'popular-series');
      final hub = tester.state<HubSectionState>(titles);
      hub.requestFocusAt(3);
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
        await settle(tester);
      }
      expect(hub.hasFocus, true);
      expect(shelfIndex(tester, titles), 0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(rail(tester, section).focusNode.hasPrimaryFocus, true);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(hub.hasFocus, true);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(find.byKey(const ValueKey('catalog-genre'))), true);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
        await settle(tester);
      }
      expect(focused(find.text('Mapped')), true);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(rail(tester, section).focusNode.hasPrimaryFocus, true);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(find.text('Mapped')), true, reason: 'Return to filters instead of the default shelf entry');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Home sidebar round trips restore the departed shelf and selected card on desktop and TV', (
    tester,
  ) async {
    for (final tv in [false, true]) {
      final client = KeyboardFixture();
      await mount(tester, client, tv: tv);
      await press(tester, LogicalKeyboardKey.arrowRight);
      for (final (id, index) in const [('next-up', 1), ('popular-movie', 2), ('popular-series', 0)]) {
        final finder = shelf(id);
        final hub = tester.state<HubSectionState>(finder);
        hub.requestFocusAt(index);
        await settle(tester);
        final expected = tester.widget<HubSection>(finder).hub.items[index].id;
        await press(tester, LogicalKeyboardKey.escape);
        expect(rail(tester, 0).focusNode.hasPrimaryFocus, true);
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(hub.hasFocus, true, reason: 'Right returns to $id instead of the first Home stop');
        expect(shelfIndex(tester, finder), index);
        await press(tester, LogicalKeyboardKey.enter);
        final movie = find.byType(TedMovieDetail);
        final initial = movie.evaluate().isNotEmpty
            ? tester.widget<TedMovieDetail>(movie).initial.media
            : find.byType(TedEpisodeDetail).evaluate().isNotEmpty
            ? tester.widget<TedEpisodeDetail>(find.byType(TedEpisodeDetail)).initial.media
            : tester.widget<TedSeriesDetail>(find.byType(TedSeriesDetail)).initial.media;
        expect('${initial.kind}/${initial.id}', expected);
        await press(tester, LogicalKeyboardKey.escape);
        await settle(tester);
        expect(hub.hasFocus, true, reason: 'Returned to $id/$expected (TV: $tv)');
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('catalogue grid and filter sidebar round trips preserve the exact card or control', (tester) async {
    for (final tv in [false, true]) {
      await mount(tester, SidebarFixture(), tv: tv);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      for (var i = 0; i < 2; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.arrowRight);
      if (tv) {
        expect(shelfIndex(tester, shelf('popular-movie')), 2);
        expect(tester.state<HubSectionState>(shelf('popular-movie')).hasFocus, true);
      } else {
        expect(focused(card(2)), true);
      }
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(find.byKey(const ValueKey('catalog-watched'))), true);
      await press(tester, LogicalKeyboardKey.escape);
      expect(rail(tester, 1).focusNode.hasPrimaryFocus, true);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(find.byKey(const ValueKey('catalog-watched'))), true);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('desktop banner actions and carousel controls return to their remembered lane from the sidebar', (
    tester,
  ) async {
    await mount(tester, KeyboardFixture(), tv: false);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(details), true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(details), true, reason: 'Up at the Home banner stays in the page');
    await press(tester, LogicalKeyboardKey.escape);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(details), true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.byTooltip('Pause carousel')), true);
    await press(tester, LogicalKeyboardKey.escape);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.byTooltip('Pause carousel')), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('banner actions, paging, pause and shelves are separate keyboard lanes with stable autoplay focus', (
    tester,
  ) async {
    TedTitle? played;
    await mount(tester, KeyboardFixture(), tv: false, play: (title) async => played = title);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(details), true);
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(pages.page, 0, reason: 'Right between action buttons must not advance the carousel');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    expect(pages.page, 1);
    expect(focused(primary), true, reason: 'Auto-paging retains the same visible action');
    expect(primary, findsOneWidget, reason: 'Offscreen slides contribute no buttons');
    await press(tester, LogicalKeyboardKey.enter);
    expect(played?.media.id, 'tt1000001');
    // Re-enter after playback returns and exercise every carousel control.
    rail(tester, 0).focusNode.requestFocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.byTooltip('Previous banner')), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.byTooltip('Pause carousel')), true);
    await press(tester, LogicalKeyboardKey.select);
    expect(focused(find.byTooltip('Resume carousel')), true);
    for (var i = 0; i < 6; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focused(find.byTooltip('Next banner')), true);
    await press(tester, LogicalKeyboardKey.enter);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(find.byTooltip('Next banner')), true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(primary), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shelves follow display order without View all, preserve card memory and reach offscreen shelves', (
    tester,
  ) async {
    await mount(tester, KeyboardFixture());
    await press(tester, LogicalKeyboardKey.arrowRight);
    final continued = find.byKey(const ValueKey('continue-watching'));
    final next = find.byKey(const ValueKey('next-up'));
    expect(find.text('View all'), findsNothing);
    expect(focused(continued), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(next), true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(continued), true, reason: 'Next Up goes directly back to Continue Watching');
    await press(tester, LogicalKeyboardKey.enter);
    expect(tester.widget<TedMovieDetail>(find.byType(TedMovieDetail)).initial.media.id, 'tt1000001');
    await press(tester, LogicalKeyboardKey.escape);
    await settle(tester);
    expect(focused(continued), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(continued), true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(
      tester.widget<TedMovieDetail>(find.byType(TedMovieDetail)).initial.media.id,
      'tt1000002',
      reason: 'Right stays on the final card',
    );
    await press(tester, LogicalKeyboardKey.escape);
    await settle(tester);
    await press(tester, LogicalKeyboardKey.tab);
    expect(focused(next), true, reason: 'Tab reaches the next shelf without a removed link');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await press(tester, LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(focused(continued), true);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focused(find.byKey(const ValueKey('popular-series'))), true);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(focused(continued), true);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(rail(tester, 0).focusNode.hasPrimaryFocus, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV banner excludes keyboard, programmatic focus, pointer and swipe interactions but still advances', (
    tester,
  ) async {
    var plays = 0;
    await mount(tester, KeyboardFixture(), play: (_) async => plays++);
    final banner = find.byType(TedHomeBanner);
    final state = tester.state<TedHomeBannerState>(banner);
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(state.requestFocus(), false);
    expect(state.requestControlsFocus(), false);
    final root = tester
        .widget<Focus>(
          find.byWidgetPredicate((widget) => widget is Focus && widget.focusNode?.debugLabel == 'ted_home_banner'),
        )
        .focusNode!;
    root.requestFocus();
    await settle(tester);
    expect(focused(banner), false);
    expect(rail(tester, 0).focusNode.hasPrimaryFocus, true);
    for (final control in [
      primary,
      details,
      find.byTooltip('Pause carousel'),
      find.byTooltip('Next banner'),
      find.byTooltip('Banner 3 of 5'),
    ]) {
      await tester.tap(control, warnIfMissed: false);
      await settle(tester);
    }
    await tester.drag(find.byType(PageView), const Offset(-700, 0), warnIfMissed: false);
    await settle(tester);
    expect(plays, 0);
    expect(find.byType(TedDetailScreen), findsNothing);
    expect(pages.page, 0);
    expect(find.byTooltip('Pause carousel'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), true);
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    expect(pages.page, 1);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV first populated shelf reveals banner and Up stays put without Continue Watching', (tester) async {
    for (final first in ['next-up', 'new-releases', 'popular-movie']) {
      final client = KeyboardFixture();
      client.homeRows = [
        const TedHomeRow('continue-watching', [], false, []),
        TedHomeRow(first, client.movies.take(3).toList(), false, []),
        TedHomeRow('popular-series', [client.show], false, []),
      ];
      await mount(tester, client, width: 1920, height: 1080);
      final shelf = find.byKey(ValueKey(first));
      final hub = tester.state<HubSectionState>(find.descendant(of: shelf, matching: find.byType(HubSection)));
      final position = Scrollable.of(tester.element(find.byType(TedHomeBanner))).position;
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(hub.hasFocus, true);
      final target = (tester.getBottomLeft(shelf).dy + position.pixels - 1080 - 18).clamp(
        0.0,
        position.maxScrollExtent,
      );
      expect(position.pixels, closeTo(target, .1));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(hub.hasFocus, true, reason: 'Up cannot leave the first visible shelf');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(hub.hasFocus, true);
      expect(position.pixels, closeTo(target, .1));
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(position.pixels, closeTo(target, .1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });

  testWidgets('TV Continue Watching reveals the banner on every focused card and retains bottom padding', (
    tester,
  ) async {
    for (final (size, episodes) in const [
      (Size(1920, 1440), true),
      (Size(1920, 1080), false),
      (Size(1200, 720), false),
    ]) {
      final client = KeyboardFixture();
      if (episodes) {
        client.continued = List.generate(
          3,
          (i) => TedTitle.fromJson(titleData(kind: 'episode', id: 'tt1000000:1:${i + 1}')),
        );
      }
      await mount(tester, client, width: size.width, height: size.height);
      final continued = find.byKey(const ValueKey('continue-watching'));
      final hub = tester.state<HubSectionState>(find.descendant(of: continued, matching: find.byType(HubSection)));
      final banner = find.byType(TedHomeBanner);
      final position = Scrollable.of(tester.element(banner)).position;
      final initialBottom = tester.getBottomLeft(continued).dy;
      var target = (initialBottom - size.height - 18).clamp(0.0, position.maxScrollExtent);
      if (episodes || size.height == 720) {
        expect(target, 0);
      } else {
        expect(target, greaterThan(0), reason: 'The short viewport cannot fit the entire banner and shelf');
      }
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(hub.hasFocus, true);
      // Recompute against settled content after the sidebar gives the shelf more width.
      target = (tester.getBottomLeft(continued).dy + position.pixels - size.height - 18).clamp(
        0.0,
        position.maxScrollExtent,
      );
      expect(position.pixels, closeTo(target, .1));
      expect(tester.getBottomLeft(continued).dy, lessThanOrEqualTo(size.height + 18 + .1));
      for (final label in find.descendant(of: continued, matching: find.byType(Text)).evaluate()) {
        expect(
          tester.getBottomLeft(find.byElementPredicate((element) => element == label)).dy,
          lessThan(size.height),
          reason: 'Visible captions remain above the edge even when the shelf gap extends below it',
        );
      }
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(position.pixels, greaterThan(target));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(hub.hasFocus, true);
      expect(position.pixels, closeTo(target, .1));
      // Moving horizontally also returns to the banner after a manual scroll.
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(position.pixels, closeTo(target, .1));
      expect(tester.getTopLeft(banner).dy, closeTo(-target, .1));
      expect(tester.getBottomLeft(continued).dy, lessThanOrEqualTo(size.height + 18 + .1));
      for (final label in find.descendant(of: continued, matching: find.byType(Text)).evaluate()) {
        expect(
          tester.getBottomLeft(find.byElementPredicate((element) => element == label)).dy,
          lessThan(size.height),
          reason: 'Focused cards retain visible captions after horizontal selection',
        );
      }
      await press(tester, LogicalKeyboardKey.enter);
      final expectedTitle = (client.continued ?? client.movies)[1];
      expect(
        expectedTitle.media.kind == 'movie'
            ? tester.widget<TedMovieDetail>(find.byType(TedMovieDetail)).initial.media
            : tester.widget<TedEpisodeDetail>(find.byType(TedEpisodeDetail)).initial.media,
        expectedTitle.media,
      );
      await press(tester, LogicalKeyboardKey.escape);
      if (episodes) {
        expect(find.byType(TedSeasonDetail), findsOneWidget);
        await press(tester, LogicalKeyboardKey.escape);
        expect(find.byType(TedSeriesDetail), findsOneWidget);
        await press(tester, LogicalKeyboardKey.escape);
      }
      await settle(tester);
      expect(hub.hasFocus, true);
      expect(position.pixels, closeTo(target, .1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('sidebar footer uses vertical arrows, preserves the view and restores account focus after its popup', (
    tester,
  ) async {
    var settings = 0, logouts = 0;
    await mount(tester, KeyboardFixture(), onSettings: () => settings++, onSignOut: () => logouts++);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focused(find.byTooltip('Reload')), true);
    expect(rail(tester, 0).isSelected, true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.byTooltip('Settings')), true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(settings, 1);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final profile = find.byTooltip('Profile: Tester');
    expect(focused(profile), true);
    await press(tester, LogicalKeyboardKey.select);
    expect(focused(find.text('Sign out')), true);
    expect(find.text('Settings'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(profile), true);
    await press(tester, LogicalKeyboardKey.enter);
    await press(tester, LogicalKeyboardKey.enter);
    expect(logouts, 1);
    expect(focused(profile), true);
    await press(tester, LogicalKeyboardKey.tab);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), true);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await press(tester, LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(focused(profile), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), true);
    await press(tester, LogicalKeyboardKey.escape);
    expect(rail(tester, 0).focusNode.hasPrimaryFocus, true);
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focused(find.byTooltip('Reload')), true, reason: 'Down from Downloads reaches bottom actions');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(
      find
          .byType(NavigationRailItem)
          .evaluate()
          .any(
            (e) =>
                (e.widget as NavigationRailItem).focusNode.hasPrimaryFocus &&
                ((e.widget as NavigationRailItem).label as Text).data == 'Downloads',
          ),
      true,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short sidebar reveals destinations above the fixed footer without activating its actions', (
    tester,
  ) async {
    var settings = 0;
    await mount(
      tester,
      KeyboardFixture(),
      height: 390,
      onSettings: () => settings++,
      displayName: 'A very long account display name',
    );
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    final downloads = find.widgetWithText(NavigationRailItem, 'Downloads');
    expect(focused(downloads), true);
    expect(tester.getBottomLeft(downloads).dy, lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('Reload')).dy));
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.byTooltip('Settings')), true);
    expect(settings, 0);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.byTooltip('Profile: A very long account display name')), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog filters, grid rows, partial final row, paging and Search preserve logical neighbours', (
    tester,
  ) async {
    final client = KeyboardFixture();
    await mount(tester, client, tv: false);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(card(0)), true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(find.text('Mapped')), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.byKey(const ValueKey('catalog-watched'))), true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(card(0)), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(card(1)), true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(card(6)), true, reason: 'Collapsed sidebar permits five columns');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(card(1)), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(card(3)), true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(card(6)), true, reason: 'A short final row clamps to its last card');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.text('Load more')), true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(client.pages.last, 50);
    await press(tester, LogicalKeyboardKey.escape);
    expect(rail(tester, 1).focusNode.hasPrimaryFocus, true);
    for (var i = 0; i < 2; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    await press(tester, LogicalKeyboardKey.enter);
    await tester.enterText(find.byType(TextField), 'the office');
    final searchField = tester.widget<TextField>(find.byType(TextField));
    searchField.controller!.selection = TextSelection.collapsed(offset: searchField.controller!.text.length);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ted_search_button');
    await press(tester, LogicalKeyboardKey.enter);
    expect(client.queries, ['movie:the office']);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(searchField.focusNode!.hasPrimaryFocus, true);
    await press(tester, LogicalKeyboardKey.tab);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ted_search_button');
    searchField.focusNode!.requestFocus();
    await settle(tester);
    // Physical Left/Right still edit text; Down leaves a single-line field.
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 2);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused(find.byType(TextField)), true, reason: '${FocusManager.instance.primaryFocus}');
    expect(field.controller!.selection.baseOffset, 1);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(card(0)), true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(find.byType(TextField)), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard activation of Settings enters its controls', (tester) async {
    await mount(tester, KeyboardFixture());
    for (var i = 0; i < 5; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focused(find.byTooltip('Settings')), true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(find.byType(TeddySettingsScreen)), true);
    expect(focused(find.byTooltip('Settings')), false);
  });

  testWidgets('Enter on Home starts its first populated row rather than the banner or remembered card', (tester) async {
    for (final tv in [false, true]) {
      final client = KeyboardFixture()
        ..homeRows = [
          const TedHomeRow('continue-watching', [], false, []),
          TedHomeRow('next-up', KeyboardFixture().movies, false, []),
        ];
      await mount(tester, client, tv: tv);
      await press(tester, LogicalKeyboardKey.enter);
      final first = tester.state<HubSectionState>(shelf('next-up'));
      expect(first.hasFocus, true);
      expect(shelfIndex(tester, shelf('next-up')), 0);
      first.requestFocusAt(3);
      await settle(tester);
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.enter);
      expect(first.hasFocus, true);
      expect(shelfIndex(tester, shelf('next-up')), 0);
    }
  });

  testWidgets('delayed keyboard activation enters loaded media but respects later sidebar movement', (tester) async {
    for (final moveAway in [false, true]) {
      final client = SidebarFixture()..heldMovie = Completer<TedCatalogPage>();
      await mount(tester, client);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(rail(tester, 1).focusNode.hasPrimaryFocus, true);
      if (moveAway) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      client.heldMovie!.complete(TedCatalogPage(client.movies, null));
      await settle(tester);
      if (moveAway) {
        expect(rail(tester, 2).focusNode.hasPrimaryFocus, true);
      } else {
        expect(focused(card(0)), true);
      }
    }
  });

  testWidgets('Up at Search, Movies and Shows top controls stays in content', (tester) async {
    for (final tv in [false, true]) {
      for (final section in ['Search', 'Movies', 'Shows']) {
        await tester.pumpWidget(const SizedBox.shrink());
        await mount(tester, KeyboardFixture(), tv: tv);
        final destination = find.byWidgetPredicate(
          (widget) => widget is NavigationRailItem && (widget.label is Text && (widget.label as Text).data == section),
        );
        tester.widget<NavigationRailItem>(destination).focusNode.requestFocus();
        await settle(tester);
        await press(tester, LogicalKeyboardKey.enter);
        await press(tester, LogicalKeyboardKey.arrowUp);
        if (section == 'Search') {
          tester.widget<TextField>(find.byType(TextField)).focusNode!.requestFocus();
          await settle(tester);
        }
        final before = FocusManager.instance.primaryFocus;
        for (var i = 0; i < 3; i++) {
          await press(tester, LogicalKeyboardKey.arrowUp);
          expect(
            FocusManager.instance.primaryFocus,
            same(before),
            reason: '$section top edge must stay in content (TV: $tv)',
          );
        }
        await press(tester, LogicalKeyboardKey.arrowDown);
        await press(tester, LogicalKeyboardKey.arrowLeft);
        expect(
          tester
              .widget<NavigationRailItem>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is NavigationRailItem && (widget.label is Text && (widget.label as Text).data == section),
                ),
              )
              .focusNode
              .hasFocus,
          true,
          reason: 'Left still enters $section sidebar (TV: $tv)',
        );
      }
    }
  });

  testWidgets('empty Home retains a usable header and compact navigation returns to visible content', (tester) async {
    await mount(tester, KeyboardFixture()..empty = true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.byTooltip('Reload')), true);
    await press(tester, LogicalKeyboardKey.escape);
    expect(rail(tester, 0).focusNode.hasPrimaryFocus, true);
    await mount(tester, KeyboardFixture(), tv: false, width: 390);
    // Tab reaches the banner; Escape hands focus to the compact navigation.
    await press(tester, LogicalKeyboardKey.tab);
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(find.byType(NavigationBar)), true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(primary), true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), true);
    expect(tester.takeException(), isNull);
  });
  testWidgets('retry and async refresh recover removed focus without stealing a later sidebar selection', (
    tester,
  ) async {
    final client = KeyboardFixture()..failHome = true;
    await mount(tester, client);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.text('Retry')), true);
    client.failHome = false;
    await press(tester, LogicalKeyboardKey.enter);
    expect(
      focused(find.byKey(const ValueKey('continue-watching'))),
      true,
      reason: 'A removed retry restores usable Home focus: ${FocusManager.instance.primaryFocus}',
    );
    await press(tester, LogicalKeyboardKey.arrowLeft);
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focused(find.byTooltip('Reload')), true);
    client.heldHome = Completer<List<TedHomeRow>>();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    rail(tester, 3).focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    client.heldHome!.complete([]);
    await settle(tester);
    expect(focused(find.byType(TextField)), true);
    expect(rail(tester, 3).isSelected, true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), false);
    expect(find.byType(MediaCard).evaluate().any((element) => focused(find.byWidget(element.widget))), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('show, season and episode cards and media menus are navigable and restore their caller', (tester) async {
    await mount(tester, PlayableKeyboardFixture());
    await press(tester, LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focused(find.byKey(const ValueKey('popular-series'))), true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byType(TedSeriesDetail), findsOneWidget);
    expect(focused(find.text('Season 1')), true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(find.text('Mark show watched')), true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.text('Season 1')), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(find.text('Specials')), true);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused(find.text('Season 1')), true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byType(TedSeasonDetail), findsOneWidget);
    expect(focused(find.byType(MediaCard)), true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(tester.widget<TedEpisodeDetail>(find.byType(TedEpisodeDetail)).initial.media.kind, 'episode');
    expect(focused(find.descendant(of: find.byType(TedPlayButton), matching: find.byType(FilledButton))), true);
    // The long Restart label wraps at this viewport. Tab follows action order
    // independently of that geometry and skips the disabled Download action.
    await press(tester, LogicalKeyboardKey.tab);
    expect(focused(find.text('Start from the beginning')), true);
    await press(tester, LogicalKeyboardKey.tab);
    expect(focused(find.text('Mark watched')), true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('Mark unwatched'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TedSeasonDetail), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TedSeriesDetail), findsOneWidget);
    expect(focused(find.text('Season 1')), true);
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(find.byKey(const ValueKey('popular-series'))), true);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    await press(tester, LogicalKeyboardKey.contextMenu);
    expect(focused(find.text('Play / Resume')), true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(find.text('Mark watched')), true);
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(find.byKey(const ValueKey('continue-watching'))), true);
    expect(tester.takeException(), isNull);
  });
}
