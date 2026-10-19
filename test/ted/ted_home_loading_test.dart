import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_catalog_test.dart' show titleData;

void main() {
  test('Home publishes personal rows before held discovery and isolates a discovery failure', () async {
    final now = DateTime.utc(2026, 10, 10);
    final movies = Completer<http.Response>(), shows = Completer<http.Response>();
    final updates = <List<TedHomeRow>>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        if (request.url.path.endsWith('/catalog/movie')) return movies.future;
        if (request.url.path.endsWith('/catalog/series')) return shows.future;
        return response({
          'titles': request.url.path.endsWith('/continue-watching') ? [titleData()] : [],
          'next_after': '',
          'issues': [],
        });
      }),
    );
    await auth.login('https://ted.example', 'fixture', '', 'Home');
    final future = TedClient(auth).home(onUpdate: updates.add);
    await Future<void>.delayed(Duration.zero);
    expect(updates.last.first.titles.single.name, 'Example movie');
    expect(updates.last[4].loading, true);
    expect(updates.last[5].loading, true);
    shows.complete(
      response({
        'titles': [titleData(kind: 'series')],
        'next_skip': null,
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(updates.last[5].titles, hasLength(1));
    expect(updates.last[4].loading, true);
    movies.complete(response({'error': 'catalog_unavailable'}, 502));
    final result = await future;
    expect(result.map((row) => row.id), [
      'continue-watching',
      'new-releases',
      'next-up',
      'watchlist',
      'popular-movie',
      'popular-series',
    ]);
    expect(result[0].titles, hasLength(1));
    expect(result[4].unavailable, true);
    expect(result.any((row) => row.loading), false);
    auth.close();
  });

  test('Home preserves sign-in-required instead of treating expired identity as empty history', () async {
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        return response({'error': 'sign_in_required'}, 401);
      }),
    );
    await auth.login('https://ted.example', 'fixture', '', 'Home');
    await expectLater(
      TedClient(auth).home(),
      throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'sign_in_required')),
    );
    auth.close();
  });
}
