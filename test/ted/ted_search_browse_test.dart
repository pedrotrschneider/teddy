import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_home_banner.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_series_detail.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import '../test_helpers/prefs.dart';
import 'ted_catalog_browse_test.dart' show CatalogBrowseFixture;
import 'ted_keyboard_navigation_test.dart' show focused;

class SearchFixture extends CatalogBrowseFixture {
  final calls = <Map<String, Object?>>[];
  Completer<TedCatalogPage>? heldSearch;
  bool failSeries = false;
  int mappedReads = 0;
  @override
  Future<TedMappedPage> mappedTitles({String? after}) async {
    mappedReads++;
    throw StateError('The removed Mapped tab must not be loaded');
  }

  @override
  Future<TedCatalogPage> browse(
    String kind, {
    String? search,
    int skip = 0,
    String catalog = 'popular',
    String genre = '',
    bool mapped = false,
    String watched = 'all',
    String? after,
  }) async {
    calls.add({
      'kind': kind,
      'query': search ?? '',
      'skip': skip,
      'catalog': catalog,
      'genre': genre,
      'mapped': mapped,
      'watched': watched,
    });
    if (search?.isNotEmpty == true) {
      if (kind == 'movie' && heldSearch != null) return heldSearch!.future;
      if (kind == 'series' && failSeries) throw const TedFailure('catalog_unavailable');
      return TedCatalogPage(entries(kind, 0), null);
    }
    return super.browse(
      kind,
      search: search,
      skip: skip,
      catalog: catalog,
      genre: genre,
      mapped: mapped,
      watched: watched,
      after: after,
    );
  }
}

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

  Future<void> mount(
    WidgetTester tester,
    SearchFixture client, {
    bool tv = false,
    Size size = const Size(1440, 900),
  }) async {
    TvDetectionService.debugReset();
    await TvDetectionService.getInstance(forceTv: tv);
    tester.view.physicalSize = size;
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
            body: TedBrowseScreen(client: client, onPlay: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder nav(String label) => find.byWidgetPredicate((w) => w is NavigationRailItem && (w.label as Text).data == label);
  final type = find.byKey(const ValueKey('search-type'));
  final field = find.byType(TextField);
  final banner = find.byKey(const ValueKey('catalog-banner'));
  Finder shelf(String kind) =>
      find.byWidgetPredicate((widget) => widget is HubSection && widget.hub.id == 'search-$kind');
  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> selectType(WidgetTester tester, String label) async {
    await tester.tap(type);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, String query) async {
    await tester.enterText(field, query);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('five destinations and Search-only controls retain grid geometry without inheriting personal filters', (
    tester,
  ) async {
    for (final size in const [Size(1440, 900), Size(390, 844), Size(320, 390)]) {
      final client = SearchFixture();
      await mount(tester, client, size: size);
      if (size.width >= 760) {
        expect(find.byType(NavigationRailItem), findsNWidgets(8));
        await tester.tap(nav('Movies'));
      } else {
        expect(find.byType(NavigationDestination), findsNWidgets(5));
        await tester.tap(find.byType(NavigationDestination).at(2));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-mapped')));
      await tester.pumpAndSettle();
      tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('catalog-watched'))).onChanged!(
        'partial',
      );
      await tester.pumpAndSettle();
      if (size.width >= 760) {
        await tester.tap(nav('Search'));
      } else {
        await tester.tap(find.byType(NavigationDestination).first);
      }
      await tester.pumpAndSettle();
      expect(find.text('Mapped items'), findsNothing);
      expect(find.byKey(const ValueKey('catalog-mapped')), findsNothing);
      expect(find.byKey(const ValueKey('catalog-watched')), findsNothing);
      expect(find.byKey(const ValueKey('catalog-genre')), findsNothing);
      expect(find.byKey(const ValueKey('catalog-order')), findsNothing);
      expect(type, findsOneWidget);
      expect(field, findsOneWidget);
      expect(client.calls.last, containsPair('mapped', false));
      expect(client.calls.last, containsPair('watched', 'all'));
      expect(client.calls.last, containsPair('genre', ''));
      expect(client.mappedReads, 0);
      expect(find.byType(HubSection), findsNothing);
      expect(find.byType(MediaCard), findsNWidgets(10));
      final card = tester.widget<MediaCard>(find.byType(MediaCard).first);
      expect(card.width, size.width >= 760 ? 180 : (size.width - 64) / 2);
      expect(card.height, closeTo((card.width! - 6) * 1.5, .01));
      if (size.width < 760) {
        expect(
          tester.getTopLeft(type).dx,
          closeTo(tester.getTopLeft(field).dx, .01),
          reason: 'Narrow controls stack on the same left edge',
        );
      }
      if (size.width >= 760) expect(tester.getRect(type).right, lessThan(tester.getRect(field).left));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a submitted query searches the selected type, displays its failure and clears back to paged discovery', (
    tester,
  ) async {
    final client = SearchFixture();
    await mount(tester, client);
    await tester.tap(nav('Search'));
    await tester.pumpAndSettle();
    await submit(tester, 'the office');
    expect(client.calls.last, containsPair('kind', 'movie'));
    expect(client.calls.where((call) => call['query'] == 'the office').length, 1);
    expect(find.text('Load more'), findsNothing);
    client.failSeries = true;
    await selectType(tester, 'Series');
    expect(client.calls.last, containsPair('kind', 'series'));
    expect(client.calls.last, containsPair('query', 'the office'));
    expect(find.text(const TedFailure('catalog_unavailable').message), findsOneWidget);
    expect(find.byType(MediaCard), findsNothing);
    client.failSeries = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaCard), findsNWidgets(10));
    await submit(tester, '');
    expect(client.calls.last, containsPair('kind', 'series'));
    expect(client.calls.last, containsPair('query', ''));
    expect(find.text('Load more'), findsOneWidget);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(client.calls.last, containsPair('skip', 50));
    expect(find.byType(MediaCard), findsNWidgets(20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('late query responses cannot replace a newly selected type or its banner', (tester) async {
    for (final fail in [false, true]) {
      final client = SearchFixture()..heldSearch = Completer<TedCatalogPage>();
      await mount(tester, client, tv: true);
      await tester.tap(nav('Search'));
      await tester.pumpAndSettle();
      // The widget fixture has no TV IME session. Supply its edited text at
      // the controller boundary and activate the production submit button.
      tester.widget<TextField>(field).controller!.text = 'held';
      await tester.tap(find.byTooltip('Search').last);
      await tester.pump();
      expect(client.calls.last, containsPair('query', 'held'));
      tester.widget<DropdownButtonFormField<String>>(type).onChanged!('series');
      await tester.pump();
      await tester.pump();
      if (fail) {
        client.heldSearch!.completeError(const TedFailure('catalog_unavailable'));
      } else {
        client.heldSearch!.complete(const TedCatalogPage([], null));
      }
      await tester.pumpAndSettle();
      expect(shelf('series'), findsOneWidget);
      expect(tester.widget<TedHomeBanner>(banner).entries.single.media.kind, 'series');
      expect(find.text(const TedFailure('catalog_unavailable').message), findsNothing);
      expect(find.text('No results.'), findsNothing);
      expect(client.calls.last, containsPair('query', 'held'));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'TV Search uses a passive spotlight, pages its shelf and preserves Type/input keyboard order and return memory',
    (tester) async {
      final client = SearchFixture();
      await mount(tester, client, tv: true);
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.enter);
      expect(focused(field), true);
      await key(tester, LogicalKeyboardKey.arrowDown);
      final hub = tester.state<HubSectionState>(shelf('movie'));
      expect(hub.hasFocus, true);
      expect(tester.state<TedHomeBannerState>(banner).requestFocus(), false);
      expect(find.descendant(of: banner, matching: find.byType(FilledButton)), findsNothing);
      expect(find.descendant(of: banner, matching: find.byType(OutlinedButton)), findsNothing);
      expect(tester.getRect(type).right, lessThan(tester.getRect(field).left));
      expect(tester.getBottomLeft(shelf('movie')).dy, lessThanOrEqualTo(900));
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(field), true);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(find.byTooltip('Search').last), true);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
      }
      expect(focused(type), true);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(
        tester.widgetList<NavigationRailItem>(find.byType(NavigationRailItem)).first.focusNode.hasPrimaryFocus,
        true,
      );
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(type), true);
      await key(tester, LogicalKeyboardKey.enter);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.enter);
      expect(client.calls.last, containsPair('kind', 'series'));
      await key(tester, LogicalKeyboardKey.arrowDown);
      final seriesHub = tester.state<HubSectionState>(shelf('series'));
      expect(seriesHub.hasFocus, true);
      seriesHub.requestFocusAt(7);
      await tester.pumpAndSettle();
      expect(client.calls.last, containsPair('skip', 50));
      expect(tester.widget<HubSection>(shelf('series')).hub.items.length, 20);
      await key(tester, LogicalKeyboardKey.escape);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.enter);
      expect(tester.widget<TedSeriesDetail>(find.byType(TedSeriesDetail)).initial.media.id, 'tt4000007');
      expect(tester.widget<TedSeriesDetail>(find.byType(TedSeriesDetail)).initial.media.kind, 'series');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Search spotlight starts enrichment only after 100ms on the same focused title', (tester) async {
    final client = SearchFixture();
    await mount(tester, client, tv: true);
    await tester.tap(nav('Search'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final hub = tester.state<HubSectionState>(shelf('movie'));
    hub.requestFocusAt(1);
    await tester.pump();
    await tester.pump();
    final count = client.details.length;
    await tester.pump(const Duration(milliseconds: 50));
    expect(client.details.length, count);
    hub.requestFocusAt(2);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 99));
    expect(client.details.length, count);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(client.details.last.id, 'tt4000002');
    expect(client.details.length, count + 1);
    expect(tester.widget<TedHomeBanner>(banner).entries.single.media.id, 'tt4000002');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
