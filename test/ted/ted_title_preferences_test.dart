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
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_rating.dart';
import 'package:plezy/ted/ted_rating_icon.dart';
import 'package:plezy/ted/ted_title_preferences_buttons.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import '../test_helpers/prefs.dart';
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
    expect(client.rating, 2);
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
  testWidgets('Watch List has only a type filter; Ratings has eight horizontal shelves', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = PersonalFixture();
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
    await tester.tap(nav('Watch List'));
    await tester.pumpAndSettle();
    expect(client.calls, ['watchlist/movie']);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Mapped'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('watchlist-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Series').last);
    await tester.pumpAndSettle();
    expect(client.calls.last, 'watchlist/series');
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
