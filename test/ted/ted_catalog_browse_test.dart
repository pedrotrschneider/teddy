import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_home_banner.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import '../test_helpers/prefs.dart';
import 'ted_auth_test.dart' show MemoryStore, pair;
import 'ted_browse_test.dart' show BrowseFixture;
import 'ted_catalog_test.dart' show titleData;
import 'ted_keyboard_navigation_test.dart' show focused;

class CatalogBrowseFixture extends BrowseFixture {
  final reads = <Map<String, Object?>>[];
  final details = <TedMediaIdentity>[];
  Completer<TedCatalogPage>? more;
  Completer<TedTitle>? heldDetail;
  bool sparse = false, failMore = false, empty = false;
  List<TedTitle> entries(String kind, int skip) => List.generate(
    10,
    (i) => TedTitle.fromJson({
      ...titleData(kind: kind, id: 'tt${4000000 + skip + i}', ready: false),
      'metadata': {'name': 'Title ${skip + i}', 'description': 'Initial ${skip + i}', 'year': '2026'},
    }),
  );
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
    reads.add({
      'kind': kind,
      'skip': skip,
      'catalog': catalog,
      'genre': genre,
      'mapped': mapped,
      'watched': watched,
      'after': after,
    });
    if (empty) return const TedCatalogPage([], null);
    if (skip > 0 && failMore) throw const TedFailure('catalog_unavailable');
    if (skip == 50 && sparse) return const TedCatalogPage([], 100);
    if (skip > 0 && more != null) return more!.future;
    return TedCatalogPage(entries(kind, skip), skip == 0 ? 50 : null);
  }

  @override
  Future<TedTitle> title(TedMediaIdentity media) async {
    // Home's separate eager metadata work is irrelevant to catalogue dwell.
    if (!media.id.startsWith('tt400')) return super.title(media);
    details.add(media);
    return heldDetail?.future ??
        TedTitle.fromJson({
          ...titleData(kind: media.kind, id: media.id, ready: false),
          'metadata': {'name': 'Enriched ${media.id}', 'description': 'Enriched description'},
        });
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

  Finder destination(String label) => find.byWidgetPredicate(
    (w) => w is NavigationRailItem && (w.label as Text).data == label || w is NavigationDestination && w.label == label,
  );

  Future<void> mount(
    WidgetTester tester,
    CatalogBrowseFixture client, {
    bool tv = true,
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
          theme: monoTheme(dark: true),
          home: Scaffold(
            body: TedBrowseScreen(client: client, onPlay: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(destination('Movies'));
    await tester.pumpAndSettle();
  }

  Future<void> key(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    Duration settle = const Duration(milliseconds: 220),
  }) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump();
    await tester.pump(settle);
  }

  Future<void> checkPosterGrid(WidgetTester tester, Size size) async {
    final client = CatalogBrowseFixture();
    await mount(tester, client, tv: false, size: size);
    await tester.tap(destination('Home'));
    await tester.pumpAndSettle();
    final homeRatios = <String, double>{};
    for (final kind in ['movie', 'series']) {
      final popularCard = find
          .descendant(of: find.byKey(ValueKey('popular-$kind')), matching: find.byType(MediaCard))
          .first;
      await tester.ensureVisible(popularCard);
      await tester.pumpAndSettle();
      final poster = find.descendant(of: popularCard, matching: find.byType(OptimizedMediaImage)).first;
      final bounds = tester.getRect(poster);
      homeRatios[kind] = bounds.height / bounds.width;
    }
    for (final section in ['Movies', 'Series']) {
      await tester.tap(destination(section));
      await tester.pumpAndSettle();
      final card = find.byType(MediaCard).first;
      final poster = find.descendant(of: card, matching: find.byType(OptimizedMediaImage)).first;
      final bounds = tester.getRect(poster);
      expect(bounds.height / bounds.width, closeTo(homeRatios[section == 'Movies' ? 'movie' : 'series']!, .001));
      expect(bounds.height / bounds.width, closeTo(1.5, .001));
      expect(bounds.width, lessThanOrEqualTo(174));
      final caption = find.descendant(of: card, matching: find.text('Title 0'));
      expect(tester.getTopLeft(caption).dy, greaterThanOrEqualTo(bounds.bottom));
      expect(find.descendant(of: card, matching: find.text('2026')), findsOneWidget);
      final second = tester.getRect(find.byType(MediaCard).at(1));
      expect(second.top, closeTo(tester.getRect(card).top, .001));
      expect(second.left, greaterThan(tester.getRect(card).right));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('desktop movie and show grid posters match Home Popular proportions with captions below', (tester) async {
    await checkPosterGrid(tester, const Size(1440, 900));
  });

  testWidgets('compact movie and show grids retain Home poster proportions in two columns', (tester) async {
    await checkPosterGrid(tester, const Size(390, 844));
  });

  Finder firstPoster(Finder scope) => find
      .descendant(
        of: find.descendant(of: scope, matching: find.byType(MediaCard)).first,
        matching: find.byType(OptimizedMediaImage),
      )
      .first;

  Future<void> checkTvAlignment(WidgetTester tester, Size size) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, CatalogBrowseFixture(), size: size);
    await tester.tap(destination('Home'));
    await tester.pumpAndSettle();
    final homePoster = firstPoster(find.byKey(const ValueKey('popular-movie')));
    await tester.ensureVisible(homePoster);
    await tester.pumpAndSettle();
    final homeLeft = tester.getTopLeft(homePoster).dx;
    double? filterGap;
    for (final section in ['Movies', 'Series']) {
      await tester.tap(destination(section));
      await tester.pumpAndSettle();
      final banner = find.byKey(const ValueKey('catalog-banner'));
      final description = find.descendant(
        of: banner,
        matching: find.byWidgetPredicate(
          (w) => w is Text && (w.data == 'Initial 0' || w.data == 'Enriched description'),
        ),
      );
      final mapped = find.byKey(const ValueKey('catalog-mapped'));
      final poster = firstPoster(find.byType(HubSection));
      final posterBounds = tester.getRect(poster);
      expect(posterBounds.left, closeTo(homeLeft, .01), reason: '$section keeps Home row spacing');
      expect(tester.getTopLeft(mapped).dx, closeTo(posterBounds.left, .01), reason: '$section filter alignment');
      expect(tester.getTopLeft(description).dx, closeTo(posterBounds.left, .01), reason: '$section banner alignment');
      final gap = posterBounds.top - tester.getBottomLeft(mapped).dy;
      filterGap ??= gap;
      expect(gap, closeTo(filterGap, .01), reason: 'Movies and Shows keep the same filter-to-poster spacing');
      expect(posterBounds.bottom, lessThanOrEqualTo(size.height));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('TV movie and show descriptions and filters align with Home posters at common window sizes', (
    tester,
  ) async {
    for (final size in const [Size(1280, 720), Size(1440, 900), Size(1920, 1080)]) {
      await checkTvAlignment(tester, size);
    }
  });

  testWidgets('TV catalogue alignment follows the Home shelf spacing preference', (tester) async {
    for (final spacing in GridSpacing.values) {
      await SettingsService.instance.write(SettingsService.gridSpacing, spacing);
      await checkTvAlignment(tester, const Size(1440, 900));
    }
  });

  testWidgets('desktop and compact catalogue filters align with unselected posters for pointer and keyboard input', (
    tester,
  ) async {
    for (final size in const [Size(1440, 900), Size(390, 844)]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, CatalogBrowseFixture(), tv: false, size: size);
      for (final section in ['Movies', 'Series']) {
        await tester.tap(destination(section));
        await tester.pumpAndSettle();
        final poster = find
            .descendant(of: find.byType(MediaCard).first, matching: find.byType(OptimizedMediaImage))
            .first;
        final mapped = find.byKey(const ValueKey('catalog-mapped'));
        expect(tester.getTopLeft(mapped).dx, closeTo(tester.getTopLeft(poster).dx, .01));
        InputModeTracker.reportNonPointerInput();
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(mapped).dx, closeTo(tester.getTopLeft(poster).dx, .01));
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop filters share movie/show requests, reset paging and keep the grid', (tester) async {
    final client = CatalogBrowseFixture();
    await mount(tester, client, tv: false);
    expect(find.byType(HubSection), findsNothing);
    expect(find.text('Load more'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('catalog-mapped')));
    await tester.pumpAndSettle();
    final watched = tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('catalog-watched')));
    watched.onChanged!('partial');
    await tester.pumpAndSettle();
    tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('catalog-genre'))).onChanged!('Drama');
    await tester.pumpAndSettle();
    expect(client.reads.last, containsPair('mapped', true));
    expect(client.reads.last, containsPair('watched', 'partial'));
    expect(client.reads.last, containsPair('genre', 'Drama'));
    expect(client.reads.last, containsPair('skip', 0));
    expect(
      tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('catalog-order'))).onChanged,
      isNull,
    );
    await tester.tap(destination('Series'));
    await tester.pumpAndSettle();
    expect(client.reads.last, containsPair('kind', 'series'));
    expect(client.reads.last, containsPair('watched', 'partial'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar enters desktop and TV media lists, Up reaches filters and returning keeps the selected title', (
    tester,
  ) async {
    for (final tv in [false, true]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, CatalogBrowseFixture(), tv: tv);
      await key(tester, LogicalKeyboardKey.arrowDown); // Home sidebar focus -> Movies
      await key(tester, LogicalKeyboardKey.enter);
      for (final section in ['Movies', 'Series']) {
        if (section == 'Series') {
          await key(tester, LogicalKeyboardKey.escape); // filters -> Movies sidebar
          await key(tester, LogicalKeyboardKey.arrowDown);
          await key(tester, LogicalKeyboardKey.enter);
        }
        void expectSelection(int index) {
          if (tv) {
            expect(tester.state<HubSectionState>(find.byType(HubSection)).hasFocus, true);
            expect(
              tester.widget<TedHomeBanner>(find.byType(TedHomeBanner)).entries.single.media.id,
              'tt${4000000 + index}',
            );
          } else {
            expect(focused(find.byType(MediaCard).at(index)), true);
          }
        }

        expectSelection(0);
        await key(tester, LogicalKeyboardKey.arrowRight);
        expectSelection(1);
        await key(tester, LogicalKeyboardKey.escape);
        final menuItem = destination(section);
        expect(tester.widget<NavigationRailItem>(menuItem).focusNode.hasPrimaryFocus, true);
        await key(tester, LogicalKeyboardKey.arrowRight);
        expectSelection(1);
        await key(tester, LogicalKeyboardKey.arrowUp);
        expect(
          focused(find.byKey(ValueKey(section == 'Movies' ? 'catalog-mapped' : 'catalog-watched'))),
          true,
          reason: 'Up enters the remembered filter in $section (TV: $tv)',
        );
        if (section == 'Series') {
          await key(tester, LogicalKeyboardKey.arrowLeft);
          expect(focused(find.byKey(const ValueKey('catalog-mapped'))), true);
        }
        await key(tester, LogicalKeyboardKey.arrowRight);
        expect(focused(find.byKey(const ValueKey('catalog-watched'))), true);
        await key(tester, LogicalKeyboardKey.arrowDown);
        expectSelection(1);
        await key(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(find.byKey(const ValueKey('catalog-watched'))), true);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sidebar retains accessible filters when desktop and TV media lists are empty', (tester) async {
    for (final tv in [false, true]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, CatalogBrowseFixture()..empty = true, tv: tv);
      expect(find.byType(HubSection), findsNothing);
      expect(find.text('No results.'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(find.byKey(const ValueKey('catalog-mapped'))), true);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(find.byKey(const ValueKey('catalog-watched'))), true);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('TV movie and series navigation never fetches detail metadata before opening a title', (tester) async {
    final client = CatalogBrowseFixture();
    await mount(tester, client);
    for (final section in ['Movies', 'Series']) {
      await tester.tap(destination(section));
      await tester.pumpAndSettle();
      client.details.clear();
      final banner = find.byKey(const ValueKey('catalog-banner'));
      expect(find.descendant(of: banner, matching: find.byType(IconButton)), findsNothing);
      expect(find.descendant(of: banner, matching: find.byType(FilledButton)), findsNothing);
      await key(tester, LogicalKeyboardKey.arrowRight, settle: Duration.zero);
      // Index 4 triggers legitimate pagination; measure focus-only rebuilds before that boundary.
      final shelf = tester.widget<HubSection>(find.byType(HubSection));
      for (var i = 1; i <= 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight, settle: const Duration(milliseconds: 150));
        expect(find.descendant(of: banner, matching: find.text('Title $i')), findsOneWidget);
      }
      await tester.pump(const Duration(seconds: 2));
      expect(client.details, isEmpty, reason: '$section navigation/dwell must not load provider details');
      expect(
        tester.widget<HubSection>(find.byType(HubSection)),
        same(shelf),
        reason: 'Focus changes must rebuild only the spotlight',
      );
      await key(tester, LogicalKeyboardKey.arrowUp);
      final filterFocus = FocusManager.instance.primaryFocus;
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(FocusManager.instance.primaryFocus, same(filterFocus));
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.enter);
      expect(
        client.details.map((m) => m.id),
        contains('tt4000003'),
        reason: 'Explicit details must still request provider enrichment',
      );
      await key(tester, LogicalKeyboardKey.escape);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV shelf appends one near-end request, keeps focus, and fences an old filtered page', (tester) async {
    final client = CatalogBrowseFixture()..more = Completer<TedCatalogPage>();
    await mount(tester, client);
    await key(tester, LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 5; i++) {
      await key(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(client.reads.where((r) => r['skip'] == 50).length, 1);
    final hub = tester.state<HubSectionState>(find.byType(HubSection));
    expect(hub.hasFocus, true);
    client.more!.complete(TedCatalogPage(client.entries('movie', 50), null));
    await tester.pumpAndSettle();
    expect(hub.itemCount, 20);
    expect(hub.hasFocus, true);
    expect(tester.widget<TedHomeBanner>(find.byType(TedHomeBanner)).entries.single.media.id, 'tt4000005');
    // Start another list then hold its second page while the genre changes.
    client.more = Completer<TedCatalogPage>();
    await tester.tap(find.byKey(const ValueKey('catalog-mapped')));
    await tester.pumpAndSettle();
    tester.state<HubSectionState>(find.byType(HubSection)).requestFocusAt(5);
    await tester.pump();
    await tester.pump();
    tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('catalog-genre'))).onChanged!('Comedy');
    await tester.pump();
    await tester.pump();
    expect(client.reads.last, containsPair('skip', 0), reason: '${client.reads}');
    client.more!.complete(TedCatalogPage(client.entries('movie', 50), null));
    await tester.pumpAndSettle();
    expect(tester.state<HubSectionState>(find.byType(HubSection)).itemCount, 10);
    expect(client.reads.last, containsPair('genre', 'Comedy'));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  test('native client encodes filters and rejects mixed/regressing catalogue cursors', () async {
    final requests = <Uri>[];
    Map<String, dynamic> response = {
      'titles': [titleData(id: 'tt4000001')],
      'next_after': 'tt4000001',
    };
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return http.Response(jsonEncode(pair(DateTime.now().toUtc())), 200);
        }
        requests.add(request.url);
        return http.Response(jsonEncode(response), 200);
      }),
    );
    addTearDown(auth.close);
    await auth.login('http://127.0.0.1:8080', 'viewer', '', 'Test');
    final client = TedClient(auth);
    await client.browse('movie', genre: 'Sci-Fi', mapped: true, watched: 'partial');
    expect(requests.single.queryParameters, containsPair('genre', 'Sci-Fi'));
    expect(requests.single.queryParameters, containsPair('mapped', 'true'));
    expect(requests.single.queryParameters, containsPair('watched', 'partial'));
    response = {...response, 'next_skip': 50};
    await expectLater(client.browse('movie'), throwsA(isA<TedFailure>()));
    response = {
      'titles': [titleData()],
      'next_skip': 50,
    };
    await expectLater(client.browse('movie', skip: 50), throwsA(isA<TedFailure>()));
    MemoryLogOutput.clearLogs();
    response = {
      'titles': [titleData()],
      'next_skip': null,
    };
    await client.browse('movie', search: 'private-query-value');
    response = {...response, 'next_skip': 50};
    await expectLater(client.browse('movie', search: 'private-query-value'), throwsA(isA<TedFailure>()));
    final messages = MemoryLogOutput.getLogs()
        .map((entry) => entry.message)
        .where((m) => m.startsWith('Catalog page'))
        .toList();
    expect(messages, hasLength(2));
    expect(messages.any((m) => m.contains('loaded kind=movie mode=search')), isTrue);
    expect(messages.any((m) => m.contains('failed kind=movie mode=search')), isTrue);
    for (final message in messages) {
      expect(message, matches(RegExp(r'elapsed_ms=\d+')));
      expect(message, isNot(contains('private-query-value')));
      expect(message, isNot(contains('/api/')));
    }
  });

  testWidgets('TV paging crosses empty genre pages and retries a failed page without clearing cards', (tester) async {
    for (final fail in [false, true]) {
      final client = CatalogBrowseFixture()
        ..sparse = !fail
        ..failMore = fail;
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, client);
      await key(tester, LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 5; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      await tester.pumpAndSettle();
      if (fail) {
        expect(find.text('Retry'), findsOneWidget);
        expect(tester.state<HubSectionState>(find.byType(HubSection)).itemCount, 10);
        client.failMore = false;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(client.reads.map((r) => r['skip']), [0, 50, 50]);
      } else {
        expect(client.reads.map((r) => r['skip']), [0, 50, 100]);
      }
      expect(tester.state<HubSectionState>(find.byType(HubSection)).itemCount, 20);
      expect(tester.widget<TedHomeBanner>(find.byType(TedHomeBanner)).entries.single.media.id, 'tt4000005');
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV catalogue keeps controls and the entire poster shelf visible at common window sizes', (tester) async {
    for (final size in const [Size(1280, 720), Size(1440, 900), Size(1920, 1080)]) {
      final client = CatalogBrowseFixture();
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, client, size: size);
      final banner = find.byKey(const ValueKey('catalog-banner'));
      final filters = find.byKey(const ValueKey('catalog-mapped'));
      final shelf = find.byType(HubSection);
      expect(tester.getTopLeft(banner).dy, 0);
      expect(tester.getBottomLeft(banner).dy, lessThanOrEqualTo(tester.getTopLeft(filters).dy));
      expect(tester.getBottomLeft(shelf).dy, lessThanOrEqualTo(size.height));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
