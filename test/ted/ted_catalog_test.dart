import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_catalog_screen.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_series_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair;

Map<String, dynamic> titleData({
  String kind = 'movie',
  String id = 'tt1234567',
  bool ready = true,
  bool played = false,
}) => {
  'media': {'kind': kind, 'id': id},
  'metadata': {
    'name': kind == 'series' ? 'Example show' : 'Example movie',
    'year': '2026',
    'description': 'Description',
    if (kind == 'episode') 'episode': {'name': 'One', 'season': 1, 'number': 1},
  },
  'watchlist': false,
  'user_rating': null,
  'watch_state': {'played': played, 'revision': 1, 'position_ms': 7000, 'duration_ms': 100000},
  'mapped_ready': ready,
  'local_available': ready,
  'metadata_status': 'fresh',
  'issues': [],
  if (kind == 'series') 'seasons': [0, 1],
};

class CatalogFixture extends TedClient {
  bool unavailable;
  bool played = false;
  final seasonsRead = <int>[];
  CatalogFixture({this.unavailable = false}) : super(TedAuth(store: MemoryStore()));
  TedTitle get movie => TedTitle.fromJson(titleData(played: played));
  TedTitle get show => TedTitle.fromJson(titleData(kind: 'series', id: 'tt8888888', ready: false, played: played));
  @override
  Future<TedSeriesWatch> seriesWatch(String id) async => TedSeriesWatch('a' * 64, 2, played ? 2 : 0);
  @override
  Future<void> setSeriesWatched(String id, String version, bool watched) async {
    played = watched;
  }

  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async => [
    TedHomeRow('continue-watching', [movie], false, []),
    const TedHomeRow('new-releases', [], false, []),
    const TedHomeRow('next-up', [], false, []),
    TedHomeRow(
      'popular-movie',
      unavailable ? [] : [movie],
      unavailable,
      unavailable ? [const TedCatalogIssue('catalog_unavailable', null)] : [],
    ),
    TedHomeRow('popular-series', [show], false, []),
  ];
  @override
  Future<TedTitle> title(TedMediaIdentity media) async => media.kind == 'series' ? show : movie;
  @override
  Future<TedEpisodePage> episodes(String id, int season, {int? after}) async {
    seasonsRead.add(season);
    return TedEpisodePage([
      TedTitle.fromJson(titleData(kind: 'episode', id: '$id:$season:1', ready: false, played: played)),
    ], null);
  }

  @override
  Future<void> setWatched(TedTitle title, bool watched) async {
    played = watched;
  }
}

void main() {
  test('catalog transport encodes search and distinguishes unpaginated search from browse slots', () async {
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
        }
        expect(request.headers['Authorization'], 'Bearer ted_a_${'a' * 43}');
        final query = request.url.queryParameters;
        if (query['search'] != null) {
          expect(query['search'], 'A&B / ?');
          expect(query['skip'], '0');
          return http.Response(
            jsonEncode({
              'titles': [titleData()],
              'next_skip': null,
            }),
            200,
            headers: {'x-ted-compatibility-version': '0.3'},
          );
        }
        expect(query['skip'], '50');
        return http.Response(
          jsonEncode({
            'titles': [titleData()],
            'next_skip': 100,
          }),
          200,
          headers: {'x-ted-compatibility-version': '0.3'},
        );
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final client = TedClient(auth);
    expect((await client.browse('movie', search: 'A&B / ?')).nextSkip, null);
    expect((await client.browse('movie', skip: 50)).nextSkip, 100);
    await expectLater(client.createSession(const TedMediaIdentity('series', 'tt1234567')), throwsA(isA<TedFailure>()));
  });

  test('client rejects malformed hierarchy, progress and paging while retaining explicit row failures', () {
    expect(TedTitle.fromJson(titleData(kind: 'series')).media.playable, false);
    for (final data in [
      {
        ...titleData(kind: 'episode', id: 'tt1234567:1:1'),
        'parent': {'kind': 'series', 'id': 'tt8888888'},
      },
      {
        ...titleData(),
        'watchlist': false,
        'user_rating': null,
        'watch_state': {'played': false, 'revision': 1, 'position_ms': -1},
      },
    ]) {
      expect(() => TedTitle.fromJson(data), throwsA(isA<TedFailure>()));
    }
    expect(() => TedCatalogPage.fromJson({'titles': [], 'next_skip': 51}), throwsA(isA<TedFailure>()));
    expect(
      () => TedPersonalPage.fromJson({'titles': [], 'issues': [], 'next_after': 'x' * 513}),
      throwsA(isA<TedFailure>()),
    );
    final row = TedHomeRow.fromJson({
      'id': 'popular-movie',
      'titles': [],
      'unavailable': true,
      'issues': [
        {'code': 'catalog_incomplete'},
      ],
    });
    expect(row.unavailable, true);
    expect(row.issues.single.message, contains('unavailable'));
  });

  testWidgets('home retains personal progress alongside a failed discovery row and opens a playable detail', (
    tester,
  ) async {
    final client = CatalogFixture(unavailable: true);
    addTearDown(client.auth.close);
    var plays = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TedCatalogScreen(
            client: client,
            onPlay: (_) async {
              plays++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('Resume 0:07'), findsOneWidget);
    final vertical = find
        .byWidgetPredicate((widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down)
        .first;
    await tester.scrollUntilVisible(find.textContaining('Cinemeta is unavailable'), 250, scrollable: vertical);
    expect(find.textContaining('Cinemeta is unavailable'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Example movie'), -250, scrollable: vertical);
    await tester.tap(find.text('Example movie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume 0:07'));
    await tester.pumpAndSettle();
    expect(plays, 1);
    await tester.tap(find.text('Mark watched'));
    await tester.pumpAndSettle();
    expect(find.text('Mark unwatched'), findsOneWidget);
  });

  testWidgets('series detail uses catalog seasons including specials and allows unmapped watched edits', (
    tester,
  ) async {
    final client = CatalogFixture();
    addTearDown(client.auth.close);
    await tester.pumpWidget(
      MaterialApp(
        home: TedTitleScreen(client: client, initial: client.show, onPlay: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(client.seasonsRead, [1]);
    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Specials').last);
    await tester.pumpAndSettle();
    expect(client.seasonsRead.last, 0);
    await tester.tap(find.byTooltip('Mark watched'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Mark unwatched'), findsOneWidget);
  });

  testWidgets('unfinished rewatch shows resume progress while preserving watched controls', (tester) async {
    final client = CatalogFixture()..played = true;
    addTearDown(client.auth.close);
    var plays = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TedCatalogScreen(
            client: client,
            onPlay: (_) async {
              plays++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Resume 0:07'), findsWidgets);
    expect(find.byType(LinearProgressIndicator), findsWidgets);
    await tester.tap(find.text('Example movie').first);
    await tester.pumpAndSettle();
    expect(find.text('Resume 0:07'), findsOneWidget);
    expect(find.text('Mark unwatched'), findsOneWidget);
    await tester.tap(find.text('Resume 0:07'));
    await tester.pumpAndSettle();
    expect(plays, 1);
    expect(client.played, true);
  });
}
