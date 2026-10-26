import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';

import 'ted_auth_test.dart' show MemoryStore, pair;
import 'ted_catalog_test.dart' show titleData;

void main() {
  test('catalog outages preserve the provider failure and a user retry succeeds without signing in', () async {
    final now = DateTime.utc(2026, 10, 11);
    for (final kind in ['movie', 'series']) {
      var calls = 0;
      final auth = TedAuth(
        store: MemoryStore(),
        now: () => now,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/login')) {
            return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
          }
          expect(request.url.path, '/api/client/v1/catalog/$kind');
          expect(request.url.queryParameters['search'], 'The Matrix');
          calls++;
          if (calls == 1) {
            return http.Response(
              jsonEncode({'code': 'catalog_unavailable', 'error': 'private upstream URL'}),
              502,
              headers: {'x-ted-compatibility-version': '0.3'},
            );
          }
          return http.Response(
            jsonEncode({
              'titles': [titleData(kind: kind)],
            }),
            200,
            headers: {'x-ted-compatibility-version': '0.3'},
          );
        }),
      );
      addTearDown(auth.close);
      await auth.login('https://ted.example', 'fixture', '', 'Desktop');
      final client = TedClient(auth);
      await expectLater(
        client.browse(kind, search: 'The Matrix'),
        throwsA(
          isA<TedFailure>()
              .having((error) => error.code, 'code', 'catalog_unavailable')
              .having((error) => error.message, 'message', startsWith('Cinemeta is unavailable.')),
        ),
      );
      expect(auth.signedIn, true);
      expect(calls, 1);
      expect((await client.browse(kind, search: 'The Matrix')).titles.single.media.kind, kind);
      expect(calls, 2);
    }
  });

  test('incomplete, missing and invalid catalog responses retain distinct fixed messages', () async {
    final now = DateTime.utc(2026, 10, 11);
    for (final failure in [('catalog_incomplete', 502), ('catalog_not_found', 404), ('catalog_invalid', 400)]) {
      final auth = TedAuth(
        store: MemoryStore(),
        now: () => now,
        client: MockClient(
          (request) async => request.url.path.endsWith('/login')
              ? http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'})
              : http.Response(
                  jsonEncode({'code': failure.$1, 'error': 'private upstream URL'}),
                  failure.$2,
                  headers: {'x-ted-compatibility-version': '0.3'},
                ),
        ),
      );
      addTearDown(auth.close);
      await auth.login('https://ted.example', 'fixture', '', 'Desktop');
      await expectLater(
        TedClient(auth).browse('movie', search: 'Example'),
        throwsA(
          isA<TedFailure>()
              .having((error) => error.code, 'code', failure.$1)
              .having((error) => error.message, 'message', isNot(contains('private upstream URL'))),
        ),
      );
    }
  });

  test('unknown server errors and transport failures still identify TED unavailability safely', () async {
    final now = DateTime.utc(2026, 10, 11);
    for (final transport in [false, true]) {
      final auth = TedAuth(
        store: MemoryStore(),
        now: () => now,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/login')) {
            return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
          }
          if (transport) throw http.ClientException('private upstream URL');
          return http.Response(
            jsonEncode({'code': 'private upstream URL', 'error': 'private upstream URL'}),
            503,
            headers: {'x-ted-compatibility-version': '0.3'},
          );
        }),
      );
      addTearDown(auth.close);
      await auth.login('https://ted.example', 'fixture', '', 'Desktop');
      await expectLater(
        TedClient(auth).browse('movie', search: 'Example'),
        throwsA(
          isA<TedFailure>()
              .having((error) => error.code, 'code', 'unavailable')
              .having((error) => error.message, 'message', startsWith('TED is unavailable.')),
        ),
      );
    }
  });
}
