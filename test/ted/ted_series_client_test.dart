import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_series_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_catalog_test.dart' show titleData;
import 'ted_metadata_client_test.dart' show metadataData;

void main() {
  test('season watch reviews and edits only the requested season, rejecting mismatched responses', () async {
    var wrongSeason = false;
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return response(pair(DateTime.now()));
        expect(r.headers['Authorization'], startsWith('Bearer ted_a_'));
        expect(r.url.path, '/api/client/v1/titles/series/tt1234567/seasons/2/watch-state');
        if (r.method == 'POST') expect(jsonDecode(r.body), {'version': 'b' * 64, 'watched': false});
        return response({
          'version': 'b' * 64,
          'items': [
            {
              'media': {'kind': 'episode', 'id': 'tt1234567:${wrongSeason ? 1 : 2}:1'},
              'revision': 4,
              'played': true,
            },
          ],
        });
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'u', '', 'Season test');
    final client = TedClient(auth);
    expect((await client.seasonWatch('tt1234567', 2)).fullyWatched, true);
    await client.setSeasonWatched('tt1234567', 2, 'b' * 64, false);
    wrongSeason = true;
    await expectLater(client.seasonWatch('tt1234567', 2), throwsA(isA<TedFailure>()));
    await expectLater(client.setSeasonWatched('tt1234567', 2, 'b' * 64, false), throwsA(isA<TedFailure>()));
    await expectLater(client.seasonWatch('tt1234567', -1), throwsA(isA<TedFailure>()));
    expect(const TedSeriesWatch('', 0, 0).fullyWatched, false);
  });
  test(
    'bulk show state validates identity and sends the reviewed version; season response retains lazy envelope',
    () async {
      final snapshot = {
        'version': 'a' * 64,
        'items': [
          {
            'media': {'kind': 'episode', 'id': 'tt1234567:1:1'},
            'revision': 3,
            'played': false,
          },
        ],
        'season_counts': {
          '1': {'total': 4, 'watched': 1},
        },
      };
      final auth = TedAuth(
        store: MemoryStore(),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/login')) return response(pair(DateTime.now()));
          expect(r.headers['Authorization'], startsWith('Bearer ted_a_'));
          if (r.url.path.endsWith('/metadata')) {
            return response({
              ...metadataData(),
              'item': {...metadataData()['item'], 'Type': 'Season'},
            });
          }
          expect(r.url.path, '/api/client/v1/titles/series/tt1234567/watch-state');
          if (r.method == 'POST') {
            expect(jsonDecode(r.body), {'version': 'a' * 64, 'watched': true});
          }
          return response(snapshot);
        }),
      );
      addTearDown(auth.close);
      await auth.login('https://ted.example', 'u', '', 'Series test');
      final client = TedClient(auth);
      final reviewed = await client.showWatch('tt1234567');
      expect(reviewed.count, 1);
      expect(reviewed.seasonCounts[1], (4, 1));
      await client.setShowWatched('tt1234567', 'a' * 64, true);
      expect((await client.season('tt1234567', 1)).type, 'Season');
      for (final bad in [
        {...snapshot, 'version': ''},
        {
          ...snapshot,
          'items': [...snapshot['items'] as List, ...snapshot['items'] as List],
        },
        {
          ...snapshot,
          'items': [
            {
              'media': {'kind': 'episode', 'id': 'tt7654321:1:1'},
              'revision': 3,
              'played': true,
            },
          ],
        },
      ]) {
        expect(() => TedSeriesWatch.fromJson(bad, 'tt1234567'), throwsA(isA<TedFailure>()));
      }
      await expectLater(client.showWatch('../wrong'), throwsA(isA<TedFailure>()));
    },
  );
  test(
    'whole-show enumeration follows paged canonical seasons including specials and rejects stalled cursors',
    () async {
      var stalled = false;
      final reads = <String>[];
      final auth = TedAuth(
        store: MemoryStore(),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/login')) return response(pair(DateTime.now()));
          final season = int.parse(r.url.queryParameters['season']!);
          final after = r.url.queryParameters['after'];
          reads.add('$season:$after');
          final number = after == null ? 1 : 2;
          return response({
            'titles': [
              {
                ...titleData(kind: 'episode', id: 'tt1234567:$season:$number'),
                'metadata': {
                  'series': {'name': 'Show'},
                  'episode': {'name': 'Episode $number', 'season': season, 'number': number},
                },
              },
            ],
            'next_after': season == 1 && (after == null || stalled) ? 1 : null,
          });
        }),
      );
      addTearDown(auth.close);
      await auth.login('https://ted.example', 'u', '', 'Series test');
      final client = TedClient(auth);
      final show = TedTitle.fromJson(titleData(kind: 'series'));
      expect((await client.allEpisodes(show)).map((t) => t.media.id), [
        'tt1234567:0:1',
        'tt1234567:1:1',
        'tt1234567:1:2',
      ]);
      expect(reads, ['0:null', '1:null', '1:1']);
      reads.clear();
      expect((await client.allEpisodes(show, season: 1)).map((t) => t.media.id), ['tt1234567:1:1', 'tt1234567:1:2']);
      expect(reads, ['1:null', '1:1']);
      reads.clear();
      expect((await client.allEpisodes(show, season: 0)).map((t) => t.media.id), ['tt1234567:0:1']);
      expect(reads, ['0:null']);
      stalled = true;
      await expectLater(client.allEpisodes(show, season: 1), throwsA(isA<TedFailure>()));
    },
  );
}
