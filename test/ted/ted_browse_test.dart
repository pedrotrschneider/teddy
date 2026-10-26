import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/models/teddy_section.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_home_banner.dart';
import 'package:plezy/ted/ted_personal_thumbnail.dart';
import 'package:plezy/ted/ted_browse_header.dart';
import 'package:plezy/ted/ted_movie_detail.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import 'package:plezy/utils/platform_detector.dart';
import '../test_helpers/prefs.dart';
import 'ted_catalog_test.dart' show CatalogFixture, titleData;
import 'ted_episode_thumbnail_test.dart' show thumbnailTitle, thumbnailMetadata;
import 'ted_home_banner_test.dart' show pixel;
import 'package:plezy/ted/ted_metadata_models.dart';

class BrowseFixture extends CatalogFixture {
  final queries = <String>[];
  final pages = <int>[];
  Completer<TedCatalogPage>? held;
  BrowseFixture({super.unavailable});
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
    if (search?.isNotEmpty == true) {
      queries.add('$kind:$search');
      if (kind == 'series') throw const TedFailure('catalog_unavailable');
      return held?.future ?? TedCatalogPage([movie], null);
    }
    pages.add(skip);
    return TedCatalogPage([
      skip == 0
          ? movie
          : TedTitle.fromJson({
              ...titleData(id: 'tt7654321'),
              'metadata': {'name': 'Second page'},
            }),
    ], skip == 0 ? 50 : null);
  }
}

class PersonalEpisodeFixture extends BrowseFixture {
  final continued = thumbnailTitle(1), upcoming = thumbnailTitle(2);
  int imageReads = 0;
  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async => [
    TedHomeRow('continue-watching', [continued], false, []),
    const TedHomeRow('new-releases', [], false, []),
    TedHomeRow('next-up', [upcoming], false, []),
    const TedHomeRow('popular-movie', [], false, []),
    const TedHomeRow('popular-series', [], false, []),
  ];
  @override
  Future<TedTitle> title(TedMediaIdentity media) async =>
      media.kind == 'series' ? show : thumbnailTitle(int.parse(media.id.split(':').last), status: 'ready');
  @override
  Future<Uint8List?> metadataImage(String id) async {
    imageReads++;
    return pixel;
  }

  @override
  Future<TedMetadataSnapshot> metadata(String id) async => TedMetadataSnapshot.fromJson(thumbnailMetadata());
  @override
  Future<TedPersonalPage> personal(String row, {String? after}) async =>
      TedPersonalPage([row == 'continue-watching' ? continued : upcoming], null, []);
}

class NewReleasesFixture extends PersonalEpisodeFixture {
  final bool duplicate;
  NewReleasesFixture({this.duplicate = false});
  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async => [
    for (final row in await super.home())
      if (row.id == 'new-releases')
        TedHomeRow('new-releases', [upcoming], false, const [])
      else if (row.id == 'next-up' && !duplicate)
        TedHomeRow('next-up', [thumbnailTitle(3)], false, const [])
      else
        row,
  ];
}

class ProgressiveHomeFixture extends BrowseFixture {
  Completer<List<TedHomeRow>>? pendingHome;
  void Function(List<TedHomeRow>)? updateHome;
  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) {
    updateHome = onUpdate;
    return pendingHome?.future ?? super.home(onUpdate: onUpdate);
  }
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });
  Future<void> mount(
    WidgetTester tester,
    BrowseFixture client, {
    double width = 1200,
    double height = 900,
    String displayName = 'Tester',
    VoidCallback? onSettings,
    VoidCallback? onReload,
    onSignOut,
  }) async {
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
              onPlay: (_) async {},
              displayName: displayName,
              onSettings: onSettings,
              onReload: onReload,
              onSignOut: onSignOut,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('startup destination is active without an Enter press and persistent sidebar stays expanded', (
    tester,
  ) async {
    await SettingsService.instance.write(SettingsService.teddyStartupSection, TeddySection.movies);
    await SettingsService.instance.write(SettingsService.alwaysKeepSidebarOpen, true);
    final client = BrowseFixture();
    await mount(tester, client);
    expect(client.pages, [0]);
    expect(find.text('Mapped'), findsOneWidget);
    final rail = find.byType(NavigationRailItem);
    expect(tester.widget<NavigationRailItem>(rail.first).isCollapsed, false);
    await tester.tap(find.byType(MediaCard).first);
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationRailItem>(rail.first).isCollapsed, false);
  });

  testWidgets('Home refresh retains loaded shelves and ignores updates after changing sections', (tester) async {
    final client = ProgressiveHomeFixture();
    var profileRefreshes = 0;
    await mount(tester, client, onReload: () => profileRefreshes++);
    client.pendingHome = Completer<List<TedHomeRow>>();
    await tester.tap(find.byTooltip('Reload'));
    expect(profileRefreshes, 1);
    await tester.pump();
    client.updateHome!([
      const TedHomeRow('continue-watching', [], false, [], loading: true),
      const TedHomeRow('popular-movie', [], true, []),
    ]);
    await tester.pump();
    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.byType(MediaCard), findsWidgets);
    expect(find.textContaining('Loading Continue Watching'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is LinearProgressIndicator && w.value == null), findsNothing);
    await tester.tap(find.byWidgetPredicate((w) => w is NavigationRailItem && (w.label as Text).data == 'Movies'));
    await tester.pumpAndSettle();
    expect(find.text('Mapped'), findsOneWidget);
    client.updateHome!([
      TedHomeRow('continue-watching', [client.movie], false, []),
    ]);
    client.pendingHome!.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Continue Watching'), findsNothing);
    expect(find.text('Mapped'), findsOneWidget);
  });

  testWidgets('fullscreen home starts behind the floating header and fits the entire first personal shelf', (
    tester,
  ) async {
    for (final size in const [Size(1440, 900), Size(1512, 950), Size(1920, 1080), Size(1280, 720)]) {
      for (final client in [BrowseFixture(), PersonalEpisodeFixture()]) {
        await mount(tester, client, width: size.width, height: size.height);
        expect(tester.getTopLeft(find.byType(TedHomeBanner)).dy, 0);
        expect(tester.getTopLeft(find.byType(TedBrowseHeader)).dy, 0);
        final shelf = find.byKey(const ValueKey('continue-watching'));
        expect(tester.getBottomLeft(shelf).dy, lessThanOrEqualTo(size.height));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('wrapped personal banner actions stay below the episode text on narrow windows', (tester) async {
    for (final width in [320.0, 390.0]) {
      await mount(tester, PersonalEpisodeFixture(), width: width, height: 640);
      final banner = find.byType(TedHomeBanner);
      final episode = find.descendant(of: banner, matching: find.textContaining('S1, E1:'));
      final play = find.descendant(of: banner, matching: find.byType(FilledButton));
      final details = find.descendant(of: banner, matching: find.byType(OutlinedButton));
      expect(episode, findsOneWidget);
      expect(play, findsOneWidget);
      expect(details, findsOneWidget);
      expect(tester.getBottomLeft(episode).dy, lessThan(tester.getTopLeft(play).dy));
      expect(tester.getRect(play).overlaps(tester.getRect(details)), isFalse);
      expect(tester.getBottomLeft(details).dy, lessThan(tester.getTopLeft(find.byTooltip('Previous banner')).dy));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('sidebar actions stay at the bottom, show the account and keep Settings outside its popup', (
    tester,
  ) async {
    var settings = 0, logouts = 0;
    await mount(
      tester,
      PersonalEpisodeFixture(),
      displayName: 'Native tester',
      onSettings: () => settings++,
      onSignOut: () => logouts++,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(20, 400));
    await tester.pumpAndSettle();
    final profile = find.byTooltip('Profile: Native tester');
    final reload = find.byTooltip('Reload'), settingsButton = find.byTooltip('Settings');
    expect(find.text('Native tester'), findsOneWidget);
    expect(find.byTooltip('Installed add-ons'), findsNothing);
    expect(tester.getRect(profile).right, lessThanOrEqualTo(220));
    expect(tester.getTopLeft(reload).dy, greaterThan(700));
    expect(tester.getBottomLeft(reload).dy, lessThanOrEqualTo(tester.getTopLeft(settingsButton).dy));
    expect(tester.getBottomLeft(settingsButton).dy, lessThanOrEqualTo(tester.getTopLeft(profile).dy));
    final original = tester.getRect(profile);
    await tester.drag(find.byType(TedHomeBanner), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.getRect(profile), original);
    await tester.tap(settingsButton);
    await tester.pumpAndSettle();
    expect(settings, 1);
    await tester.tap(profile);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget, reason: 'Only the sidebar, not the popup');
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(logouts, 1);
    expect(find.text('Sign out'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mouse hover expands every sidebar icon with a pointer cursor and collapse releases content width', (
    tester,
  ) async {
    await mount(tester, BrowseFixture(), onSettings: () {}, onSignOut: () {});
    final sidebar = find.byKey(const ValueKey('ted-sidebar'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(1000, 30));
    await tester.pumpAndSettle();
    final collapsedWidth = tester.getSize(sidebar).width;
    expect(collapsedWidth, 80);
    expect(tester.widgetList<NavigationRailItem>(find.byType(NavigationRailItem)).every((w) => w.isCollapsed), true);
    final banner = find.byType(TedHomeBanner);
    expect(tester.getTopLeft(banner).dx, 80);
    await mouse.moveTo(const Offset(20, 90));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 220);
    expect(tester.getTopLeft(banner).dx, 220);
    final rows = tester.widgetList<NavigationRailItem>(find.byType(NavigationRailItem)).toList();
    for (final row in rows) {
      final target = find.byWidget(row);
      await mouse.moveTo(tester.getCenter(target));
      await tester.pumpAndSettle();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
        reason: (row.label as Text).data,
      );
    }
    await mouse.moveTo(const Offset(1000, 30));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, collapsedWidth);
    expect(tester.widgetList<NavigationRailItem>(find.byType(NavigationRailItem)).every((w) => w.isCollapsed), true);
    // Clicking the collapsed icon still opens the selected destination.
    final movie = find.byWidgetPredicate((w) => w is NavigationRailItem && (w.label as Text).data == 'Movies');
    await tester.tap(movie);
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationRailItem>(movie).isSelected, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard focus and account popup retain expansion until returning to media content', (tester) async {
    await mount(tester, BrowseFixture(), onSettings: () {}, onSignOut: () {});
    final sidebar = find.byKey(const ValueKey('ted-sidebar'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(tester.getSize(sidebar).width, 80);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 220);
    final account = tester.widgetList<NavigationRailItem>(find.byType(NavigationRailItem)).last;
    account.focusNode.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Sign out'), findsOneWidget);
    expect(tester.getSize(sidebar).width, 220);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(account.focusNode.hasPrimaryFocus, true);
    expect(tester.getSize(sidebar).width, 220);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(tester.getSize(sidebar).width, 80);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop and TV use the same collapsed width and center every sidebar icon', (tester) async {
    addTearDown(TvDetectionService.debugReset);
    for (final tv in [false, true]) {
      await tester.pumpWidget(const SizedBox.shrink());
      TvDetectionService.debugReset();
      await TvDetectionService.getInstance(forceTv: tv);
      await mount(tester, BrowseFixture(), onSettings: () {}, onSignOut: () {});
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final sidebar = find.byKey(const ValueKey('ted-sidebar'));
      expect(tester.getSize(sidebar).width, 80);
      expect(tester.getTopLeft(find.byType(TedHomeBanner)).dx, 80);
      for (final row in tester.widgetList<NavigationRailItem>(find.byType(NavigationRailItem))) {
        expect(row.isCollapsed, true);
        expect(tester.getSize(find.byWidget(row)).width, 72);
        expect(tester.getCenter(find.byWidget(row)).dx, 40);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 220);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('compact controls fit small windows and disabled sign out remains disabled', (tester) async {
    var settings = 0;
    for (final size in const [Size(390, 844), Size(740, 390), Size(320, 390)]) {
      await mount(
        tester,
        PersonalEpisodeFixture(),
        width: size.width,
        height: size.height,
        displayName: 'A',
        onSettings: () => settings++,
      );
      final profile = find.byTooltip('Profile: A');
      expect(tester.getRect(profile).right, lessThanOrEqualTo(size.width));
      await tester.tap(profile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NavigationDestination).first);
      await tester.pumpAndSettle();
      final search = find.widgetWithText(TextField, 'Search movies and series');
      await tester.enterText(search, 'the office');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(settings, 3);
  });

  testWidgets('home uses shared cards and retains Continue Watching alongside discovery errors', (tester) async {
    final client = BrowseFixture(unavailable: true);
    await mount(tester, client);
    expect(find.byType(MediaCard), findsWidgets);
    expect(find.text('Continue Watching'), findsOneWidget);
    final vertical = find
        .byWidgetPredicate((widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down)
        .first;
    await tester.scrollUntilVisible(find.textContaining('Cinemeta is unavailable'), 250, scrollable: vertical);
    expect(find.textContaining('Cinemeta is unavailable'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Continue Watching'), -250, scrollable: vertical);
    await tester.ensureVisible(find.byType(MediaCard).first);
    await tester.tap(find.byType(MediaCard).first);
    await tester.pumpAndSettle();
    expect(find.byType(TedMovieDetail), findsOneWidget);
    expect(find.text('2 min left'), findsOneWidget);
    await tester.tap(find.text('Mark watched'));
    await tester.pumpAndSettle();
    expect(find.text('Mark unwatched'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TedBrowseScreen), findsOneWidget);
  });

  testWidgets('New Releases follows Continue Watching with episode artwork and keyboard row navigation', (
    tester,
  ) async {
    addTearDown(TvDetectionService.debugReset);
    await TvDetectionService.getInstance(forceTv: true);
    await mount(tester, NewReleasesFixture(), height: 1100);
    final continued = find.byKey(const ValueKey('continue-watching'));
    final releases = find.byKey(const ValueKey('new-releases'));
    final next = find.byKey(const ValueKey('next-up'));
    expect(find.text('New Releases'), findsOneWidget);
    expect(tester.getTopLeft(releases).dy, greaterThan(tester.getTopLeft(continued).dy));
    expect(tester.getTopLeft(releases).dy, lessThan(tester.getTopLeft(next).dy));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final releaseHub = find.descendant(of: releases, matching: find.byType(HubSection));
    expect(tester.state<HubSectionState>(releaseHub).hasFocus, true);
    expect(find.descendant(of: releases, matching: find.byType(TedPersonalThumbnail)), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tester.state<HubSectionState>(find.descendant(of: next, matching: find.byType(HubSection))).hasFocus, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlapping retained episode appears only on the New Releases shelf', (tester) async {
    await mount(tester, NewReleasesFixture(duplicate: true));
    final releases = find.byKey(const ValueKey('new-releases'));
    expect(releases, findsOneWidget);
    expect(find.byKey(const ValueKey('next-up')), findsNothing);
    expect(find.descendant(of: releases, matching: find.byType(TedPersonalThumbnail)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home uses the reduced row gap below the carousel on desktop and phone', (tester) async {
    for (final width in [1200.0, 390.0]) {
      final client = BrowseFixture();
      await mount(tester, client, width: width);
      final bannerBottom = tester.getBottomLeft(find.byType(TedHomeBanner)).dy;
      final headingTop = tester.getTopLeft(find.text('Continue Watching')).dy;
      // 60% of the former 32px gap plus the unchanged 4px heading inset.
      expect(headingTop - bannerBottom, closeTo(32 * .6 + 4, .1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('personal home shelves retain episode thumbnails and navigation without View all buttons', (
    tester,
  ) async {
    for (final width in [1200.0, 390.0]) {
      final client = PersonalEpisodeFixture();
      await mount(tester, client, width: width);
      expect(find.text('View all'), findsNothing);
      final cw = find.byKey(const ValueKey('continue-watching'));
      expect(
        tester.widget<HubSection>(find.descendant(of: cw, matching: find.byType(HubSection))).episodePosterModeOverride,
        EpisodePosterMode.episodeThumbnail,
      );
      final next = find.byKey(const ValueKey('next-up'));
      final vertical = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
      await tester.scrollUntilVisible(next, 200, scrollable: vertical);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<HubSection>(find.descendant(of: next, matching: find.byType(HubSection)))
            .episodePosterModeOverride,
        EpisodePosterMode.episodeThumbnail,
      );
      expect(find.descendant(of: next, matching: find.byType(TedPersonalThumbnail)), findsOneWidget);
      expect(tester.takeException(), isNull);
      // The header's tooltip surrogate does not expose a revealable scroll
      // target; return the real home scroller to its beginning before tapping.
      tester.state<ScrollableState>(vertical).position.jumpTo(0);
      await tester.pumpAndSettle();
      final imagesBeforeReload = client.imageReads;
      await tester.tap(find.byTooltip('Reload'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(cw, 200, scrollable: vertical);
      await tester.pumpAndSettle();
      expect(client.imageReads, greaterThan(imagesBeforeReload));
      final cardFinder = find.descendant(of: cw, matching: find.byType(MediaCard)).first;
      final card = tester.widget<MediaCard>(cardFinder);
      expect((card.item as MediaItem).id, 'episode/tt1234567:1:1');
      expect(card.episodePosterModeOverride, EpisodePosterMode.episodeThumbnail);
      expect(find.descendant(of: cw, matching: find.byType(TedPersonalThumbnail)), findsOneWidget);
      await tester.ensureVisible(cardFinder);
      await tester.tap(cardFinder);
      await tester.pumpAndSettle();
      expect(tester.widget<TedEpisodeDetail>(find.byType(TedEpisodeDetail)).initial.media, client.continued.media);
      expect(tester.takeException(), isNull);
      // A new size/client must start with a fresh Navigator, not retain the
      // details route from the previous iteration.
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('search uses only the selected category and stale requests cannot overwrite navigation', (tester) async {
    final client = BrowseFixture();
    await mount(tester, client);
    await tester.tap(find.byWidgetPredicate((w) => w is NavigationRailItem && (w.label as Text).data == 'Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'the office');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(client.queries, ['movie:the office']);
    expect(find.byType(MediaCard), findsOneWidget);
    expect(find.textContaining('Cinemeta is unavailable'), findsNothing);
    client.held = Completer();
    await tester.enterText(find.byType(TextField), 'late');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.byWidgetPredicate((w) => w is NavigationRailItem && (w.label as Text).data == 'Movies'));
    await tester.pumpAndSettle();
    client.held!.complete(TedCatalogPage([], null));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is NavigationRailItem && (w.label as Text).data == 'Movies'),
      findsOneWidget,
    );
    expect(find.byType(MediaCard), findsOneWidget);
    expect(find.text('No results.'), findsNothing);
  });

  testWidgets('returning from a paged title preserves cards and paging state', (tester) async {
    final client = BrowseFixture();
    await mount(tester, client);
    await tester.tap(find.byWidgetPredicate((w) => w is NavigationRailItem && (w.label as Text).data == 'Movies'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(client.pages, [0, 50]);
    expect(find.byType(MediaCard), findsNWidgets(2));
    await tester.tap(find.byType(MediaCard).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(client.pages, [0, 50]);
    expect(find.byType(MediaCard), findsNWidgets(2));
    expect(find.text('Load more'), findsNothing);
  });

  testWidgets('phone navigation and show specials use the same shared detail flow', (tester) async {
    final client = BrowseFixture();
    await mount(tester, client, width: 390);
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: TedDetailScreen(client: client, initial: client.show, onPlay: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(client.seasonsRead.last, 1);
    await tester.tap(find.text('Specials'));
    await tester.pumpAndSettle();
    expect(client.seasonsRead.last, 0);
    expect(find.byType(MediaCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard activates the existing Plezy navigation rail', (tester) async {
    final client = BrowseFixture();
    await mount(tester, client);
    final item = tester.widgetList<NavigationRailItem>(find.byType(NavigationRailItem)).elementAt(0);
    item.focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });
}
