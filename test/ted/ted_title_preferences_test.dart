import 'package:plezy/ted/ted_presentation.dart';
import 'package:plezy/widgets/watched_indicator.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_home_banner.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_rating.dart';
import 'package:plezy/ted/ted_rating_icon.dart';
import 'package:plezy/ted/ted_title_preferences_buttons.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/ted_navigation.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_catalog_test.dart' show CatalogFixture, titleData;

class PersonalFixture extends CatalogFixture {
  final calls = <String>[];
  bool saved = false;
  int? rating;
  bool reject = false;
  @override
  Future<TedTitlePreferences> setTitlePreference(
    TedMediaIdentity media,
    String field, {
    bool? watchlist,
    int? rating,
  }) async {
    if (reject) throw const TedFailure('unavailable');
    if (field == 'watchlist') {
      saved = watchlist!;
    } else {
      this.rating = rating;
    }
    return TedTitlePreferences(saved, this.rating);
  }

  @override
  Future<TedPersonalPage> collection(String list, {String kind = '', String? after}) async {
    calls.add('$list/$kind');
    return TedPersonalPage(
      [
        TedTitle.fromJson({
          ...titleData(kind: kind.isEmpty ? 'movie' : kind),
          'watchlist': saved,
          'user_rating': rating,
        }),
      ],
      null,
      const [],
    );
  }
}

class BannerPreferencesFixture extends PersonalFixture {
  final prefReads = <TedMediaIdentity>[];
  final edits = <(TedMediaIdentity, String)>[];
  final bool episodeBanner;
  int detailReads = 0;
  BannerPreferencesFixture({required this.episodeBanner});

  @override
  TedTitle get movie => super.movie.withPreferences(TedTitlePreferences(saved, rating));
  @override
  TedTitle get show => super.show.withPreferences(TedTitlePreferences(saved, rating));
  @override
  Future<TedCatalogPage> browse(
    String kind, {
    String search = '',
    int skip = 0,
    String catalog = 'popular',
    String genre = '',
    bool mapped = false,
    String watched = 'all',
    String? after,
  }) async => TedCatalogPage([kind == 'series' ? show : movie], null);

  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async => [
    if (episodeBanner)
      TedHomeRow(
        'next-up',
        [
          TedTitle.fromJson({
            ...titleData(kind: 'episode', id: '${show.media.id}:1:2'),
            'parent': show.media.toJson(),
            'series': {'name': show.name},
          }),
        ],
        false,
        const [],
      )
    else
      TedHomeRow('popular-movie', [movie], false, const []),
    if (saved) TedHomeRow('watchlist', [episodeBanner ? show : movie], false, const []),
  ];

  @override
  Future<TedTitle> title(TedMediaIdentity media) {
    detailReads++;
    return super.title(media);
  }

  @override
  Future<TedTitlePreferences> titlePreferences(TedMediaIdentity media) async {
    prefReads.add(media);
    return TedTitlePreferences(saved, rating);
  }

  @override
  Future<TedTitlePreferences> setTitlePreference(TedMediaIdentity media, String field, {bool? watchlist, int? rating}) {
    edits.add((media, field));
    return super.setTitlePreference(media, field, watchlist: watchlist, rating: rating);
  }
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    PlatformDetector.debugSetIsDesktopOSOverride(true);
  });
  tearDown(() => PlatformDetector.debugSetIsDesktopOSOverride(null));
  test('0.3 requires personal fields and sends independent scoped mutations', () async {
    final raw = titleData();
    for (final key in ['watchlist', 'user_rating']) {
      final missing = {...raw}..remove(key);
      expect(() => TedTitle.fromJson(missing), throwsA(isA<TedFailure>()));
    }
    expect(() => TedTitle.fromJson({...raw, 'user_rating': 8}), throwsA(isA<TedFailure>()));
    final now = DateTime.utc(2026, 10, 19);
    final bodies = <Object?>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        expect(r.headers['X-Teddy-Compatibility-Version'], '0.3');
        if (r.url.path.endsWith('/login')) return response(pair(now));
        expect(r.url.path, '/api/client/v1/titles/movie/tt1234567/preferences/rating');
        bodies.add(jsonDecode(r.body));
        return response({'watchlist': true, 'user_rating': null});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final state = await TedClient(
      auth,
    ).setTitlePreference(const TedMediaIdentity('movie', 'tt1234567'), 'rating', rating: null);
    expect(state.watchlist, true);
    expect(state.rating, isNull);
    expect(bodies, [
      {'user_rating': null},
    ]);
    await expectLater(
      TedClient(auth).setTitlePreference(const TedMediaIdentity('episode', 'tt1234567:1:1'), 'rating', rating: 5),
      throwsA(isA<TedFailure>()),
    );
  });
  testWidgets('save, choose, adjust and clear ratings without changing watch-list membership', (tester) async {
    final client = PersonalFixture();
    addTearDown(client.auth.close);
    var title = client.movie;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TedTitlePreferencesButtons(
              client: client,
              title: title,
              onChanged: (state) => setState(() => title = title.withPreferences(state)),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add to Watch List'));
    await tester.pumpAndSettle();
    expect(client.saved, true);
    await tester.tap(find.text('Rate'));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialogOption), findsNWidgets(8));
    final options = find.byType(SimpleDialogOption);
    expect(find.descendant(of: options.first, matching: find.text('Absolute cinema')), findsOneWidget);
    expect(find.descendant(of: options.at(6), matching: find.text('Absolute trash')), findsOneWidget);
    await tester.tap(find.text('Absolute cinema'));
    await tester.pumpAndSettle();
    expect(client.rating, 7);
    expect(find.byType(TedRatingBadge), findsOneWidget);
    await tester.tap(find.text('Absolute cinema'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Good'));
    await tester.pumpAndSettle();
    expect(client.rating, 5);
    await tester.tap(find.text('Good'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear rating'));
    await tester.pumpAndSettle();
    expect(client.rating, isNull);
    expect(client.saved, true);
    client.reject = true;
    await tester.tap(find.text('Remove from Watch List'));
    await tester.pumpAndSettle();
    expect(client.saved, true);
    expect(find.text('Remove from Watch List'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('keyboard rating picker chooses a category and poster badges keep their corners', (tester) async {
    final client = PersonalFixture();
    addTearDown(client.auth.close);
    var title = client.movie;
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => TedTitlePreferencesButtons(
                client: client,
                title: title,
                onChanged: (state) => setState(() => title = title.withPreferences(state)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Rate'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.rating, 6);
    expect(find.byType(SimpleDialog), findsNothing);
    final decorated = TedTitle.fromJson({
      ...titleData(),
      'watchlist': true,
      'user_rating': 7,
      'user_watches': [
        {
          'account_id': 2,
          'name': 'Clara',
          'rating': 5,
          'watch': {'seen': true, 'watched': 0, 'available': 1, 'progress': 25},
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 270,
              child: WatchedIndicator(item: TedPresentation(client).item(decorated)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final own = find.byWidgetPredicate((w) => w is TedRatingBadge && w.rating == 7),
        peer = find.byWidgetPredicate((w) => w is TedRatingBadge && w.rating == 5);
    expect(own, findsOneWidget);
    expect(peer, findsOneWidget);
    final poster = tester.getRect(find.byType(WatchedIndicator));
    expect(tester.getRect(own).center.dx, lessThan(poster.center.dx));
    expect(tester.getRect(own).center.dy, greaterThan(poster.center.dy));
    final avatar = find.descendant(of: find.byType(TedOtherWatchBadge), matching: find.byType(SizedBox)).first;
    final avatarBounds = tester.getRect(avatar);
    final peerBounds = tester.getRect(peer);
    expect(peerBounds.right, closeTo(avatarBounds.right + avatarBounds.width * .15, .01));
    expect(peerBounds.top, closeTo(avatarBounds.top - avatarBounds.width * .15, .01));
    expect((peerBounds.center - avatarBounds.center).distance, greaterThan(peerBounds.width / 2));
    expect(tester.getRect(peer).center.dy, lessThan(poster.center.dy));
    expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final tv in [false, true]) {
    testWidgets('holding a Home banner saves and rates the whole title without opening details (TV: $tv)', (
      tester,
    ) async {
      TvDetectionService.debugReset();
      (await TvDetectionService.getInstance()).setForceTv(tv);
      addTearDown(TvDetectionService.debugReset);
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = BannerPreferencesFixture(episodeBanner: tv);
      addTearDown(client.auth.close);
      final target = tv ? client.show.media : client.movie.media;
      await tester.pumpWidget(
        InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(dark: true),
            home: Scaffold(
              body: TedBrowseScreen(client: client, onPlay: (_) async => fail('Holding a banner must not play it')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final banner = find.byType(TedHomeBanner);
      await tester.longPress(banner);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to Watch List'));
      await tester.pumpAndSettle();
      expect(client.edits, [(target, 'watchlist')]);
      expect(find.byKey(const ValueKey('watchlist')), findsOneWidget);
      await tester.longPress(banner);
      await tester.pumpAndSettle();
      expect(find.text('Remove from Watch List'), findsOneWidget);
      final detailsBeforeRating = client.detailReads;
      await tester.tap(find.text(tv ? 'Rate series' : 'Rate'));
      await tester.pumpAndSettle();
      expect(client.detailReads, detailsBeforeRating);
      await tester.tap(find.text('Absolute cinema'));
      await tester.pumpAndSettle();
      expect(client.edits, [(target, 'watchlist'), (target, 'rating')]);
      expect(client.rating, 7);
      expect(client.prefReads, tv ? [target, target] : isEmpty);
      expect(find.byType(TedHomeBanner), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Discover spotlight and a held TV Select on its card share the rating action', (tester) async {
    TvDetectionService.debugReset();
    (await TvDetectionService.getInstance()).setForceTv(true);
    addTearDown(TvDetectionService.debugReset);
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = BannerPreferencesFixture(episodeBanner: false);
    addTearDown(client.auth.close);
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: Scaffold(
            body: TedBrowseScreen(client: client, onPlay: (_) async => fail('Holding a banner must not play it')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final discover = find.byWidgetPredicate(
      (widget) => widget is NavigationRailItem && (widget.label as Text).data == 'Discover',
    );
    await tester.tap(discover);
    await tester.pumpAndSettle();
    await chooseTedDiscoverType(tester, 'Series');
    final detailReads = client.detailReads;
    final banner = find.byKey(const ValueKey('catalog-banner'));
    await tester.longPress(banner);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to Watch List'));
    await tester.pumpAndSettle();

    tester.state<HubSectionState>(find.byType(HubSection)).requestFocusAt(0);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 550));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Remove from Watch List'), findsOneWidget);
    await tester.tap(find.text('Rate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Very Good'));
    await tester.pumpAndSettle();
    expect(client.edits, [(client.show.media, 'watchlist'), (client.show.media, 'rating')]);
    expect(client.rating, 6);
    expect(client.detailReads, detailReads);
    expect(banner, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Discover Watch List uses the saved collection and Ratings retains eight shelves', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = PersonalFixture()..saved = true;
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
    Finder nav(String label) =>
        find.byWidgetPredicate((w) => w is NavigationRailItem && (w.label as Text).data == label);
    await tester.tap(nav('Discover'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('discover-watchlist')));
    await tester.pumpAndSettle();
    expect(client.calls, ['watchlist/movie']);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Mapped'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('discover-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Series').last);
    await tester.pumpAndSettle();
    expect(client.calls.last, 'watchlist/series');
    await tester.tap(find.byKey(const ValueKey('discover-watchlist')));
    await tester.pumpAndSettle();
    expect(client.calls, ['watchlist/movie', 'watchlist/series']);
    expect(find.byKey(const ValueKey('catalog-mapped')), findsOneWidget);
    expect(nav('Watch List'), findsNothing);
    await tester.tap(nav('Ratings'));
    await tester.pumpAndSettle();
    expect(client.calls.where((v) => v.startsWith('ratings/')).length, 8);
    final hubs = tester.widgetList<HubSection>(find.byType(HubSection)).toList();
    expect(hubs.length, 8);
    expect(hubs.last.hub.title, 'Unrated');
    expect(hubs.first.hub.title, 'Absolute cinema');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
