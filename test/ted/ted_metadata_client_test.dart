import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'package:plezy/ted/ted_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair;

const itemId = '11111111-1111-4111-8111-111111111111';
const assetId = '22222222-2222-4222-8222-222222222222';
Map<String, dynamic> metadataData({String status = 'ready', bool images = false}) => {
  'item': {
    'Id': itemId,
    'Type': 'Movie',
    'Name': 'Provider title',
    'Overview': 'Provider description',
    'CommunityRating': 8.5,
    'ProductionYear': 2026,
  },
  'status': status,
  'generation': 1,
  'images': [
    if (images)
      {
        'id': assetId,
        'type': 'Backdrop',
        'index': 0,
        'status': 'new',
        'url': '/api/client/v1/metadata/images/$assetId',
      },
  ],
};
void main() {
  test('person details retain media server dates/locations and typed paginated personal credit summaries', () async {
    final now = DateTime.utc(2026, 10, 11);
    final person = metadataData();
    person['item'] = <String, dynamic>{
      'Id': itemId,
      'Name': 'Actor',
      'Type': 'Person',
      'PremiereDate': '1974-01-30T00:00:00Z',
      'EndDate': '2020-10-11T00:00:00Z',
      'ProductionLocations': ['Wales'],
    };
    final summary = <String, dynamic>{
      'item': <String, dynamic>{'Id': assetId, 'Name': 'An appearance', 'Type': 'Series'},
      'media': <String, dynamic>{'kind': 'series', 'id': 'tt0386676'},
      'watchlist': false,
      'user_rating': null,
      'identity_status': 'ready',
      'watched': false,
      'viewed': true,
      'images': [],
      'roles': ['Character'],
      'episode_counts': {'total': 12, 'watched': 4},
    };
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.2'});
        }
        expect(request.headers['Authorization'], 'Bearer ted_a_${'a' * 43}');
        if (request.url.path.endsWith('/filmography')) {
          expect(request.url.queryParameters, {'after': assetId});
          return http.Response(
            jsonEncode({
              'items': [summary],
            }),
            200,
            headers: {'x-ted-compatibility-version': '0.2'},
          );
        }
        expect(request.url.path, '/api/client/v1/metadata/people/$itemId');
        return http.Response(jsonEncode(person), 200, headers: {'x-ted-compatibility-version': '0.2'});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'u', '', 'Person fixture');
    final client = TedClient(auth), value = await client.person(itemId);
    expect(value.premiereDate, DateTime.utc(1974, 1, 30));
    expect(value.productionLocations, ['Wales']);
    final page = await client.filmography(itemId, after: assetId);
    expect(page.items.single.viewed, true);
    expect(page.items.single.watched, false);
    expect(page.items.single.episodeCount, 12);
    expect(page.items.single.watchedEpisodeCount, 4);
    for (final counts in [
      {'total': 2, 'watched': 3},
      {'total': -1, 'watched': 0},
    ]) {
      expect(() => TedFilmographyEntry.fromJson({...summary, 'episode_counts': counts}), throwsA(isA<TedFailure>()));
    }
    expect(page.items.single.media, const TedMediaIdentity('series', 'tt0386676'));
    await expectLater(client.filmography(itemId, after: '../escape'), throwsA(isA<TedFailure>()));
    person['item']['Type'] = 'Movie';
    await expectLater(client.person(itemId), throwsA(isA<TedFailure>()));
    summary['media'] = null;
    expect(
      () => TedFilmographyPage.fromJson({
        'items': [summary],
      }),
      throwsA(isA<TedFailure>()),
    );
    expect(() => TedFilmographyPage.fromJson({'items': [], 'next_after': 'provider-url'}), throwsA(isA<TedFailure>()));
  });

  test('artwork and JSON share one refresh owner and retry with the new bearer', () async {
    final now = DateTime.utc(2026, 10, 11),
        release = Completer<void>(),
        entered = Completer<void>(),
        rejectedTogether = Completer<void>();
    int rotations = 0, rejected = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.2'});
        }
        if (request.url.path.endsWith('/refresh')) {
          rotations++;
          entered.complete();
          await release.future;
          return http.Response(
            jsonEncode(pair(now, suffix: 'b')),
            200,
            headers: {'x-ted-compatibility-version': '0.2'},
          );
        }
        expect(request.url.host, 'ted.example');
        expect(request.url.hasQuery, false);
        if (request.headers['Authorization'] == 'Bearer ted_a_${'a' * 43}') {
          rejected++;
          if (rejected == 2) rejectedTogether.complete();
          await rejectedTogether.future;
          return http.Response('{}', 401, headers: {'x-ted-compatibility-version': '0.2'});
        }
        expect(request.headers['Authorization'], 'Bearer ted_a_${'b' * 43}');
        if (request.url.path.contains('/images/')) {
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'x-ted-compatibility-version': '0.2', 'content-type': 'image/png'},
          );
        }
        return http.Response(jsonEncode(metadataData()), 200, headers: {'x-ted-compatibility-version': '0.2'});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'u', '', 'Fixture');
    final client = TedClient(auth), calls = [client.metadata(itemId), client.metadataImage(assetId)];
    await entered.future;
    release.complete();
    final responses = await Future.wait(calls);
    expect(rotations, 1);
    expect(rejected, 2);
    expect((responses.first as TedMetadataSnapshot).name, 'Provider title');
    expect(responses.last, [1, 2, 3]);
  });
  test('pending image responses are distinct from bytes, malformed data and redirects', () async {
    final now = DateTime.utc(2026, 10, 11);
    int status = 202;
    String contentType = 'application/json';
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.2'});
        }
        return http.Response(
          '{}',
          status,
          headers: {'x-ted-compatibility-version': '0.2', 'content-type': contentType},
        );
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'u', '', 'Fixture');
    final client = TedClient(auth);
    expect(await client.metadataImage(assetId), isNull);
    status = 200;
    await expectLater(client.metadataImage(assetId), throwsA(isA<TedFailure>()));
    status = 302;
    contentType = 'image/png';
    await expectLater(client.metadataImage(assetId), throwsA(isA<TedFailure>()));
    await expectLater(client.metadataImage('https://other.example/image'), throwsA(isA<TedFailure>()));
    final bad = metadataData(images: true);
    (bad['images'] as List).first['url'] = 'https://other.example/image';
    expect(() => TedMetadataSnapshot.fromJson(bad), throwsA(isA<TedFailure>()));
  });

  test('credits retain stable person IDs, provider order, roles and optional portrait tags', () {
    final data = metadataData();
    data['item']['People'] = [
      {'Id': itemId, 'Name': 'First Actor', 'Type': 'Actor', 'Role': 'Lead', 'PrimaryImageTag': 'portrait-revision'},
      {'Id': assetId, 'Name': 'Writer', 'Type': 'Writer'},
    ];
    final people = TedMetadataSnapshot.fromJson(data).people;
    expect(people.map((p) => p.name), ['First Actor', 'Writer']);
    expect(people.first.id, itemId);
    expect(people.first.role, 'Lead');
    expect(people.first.imageTag, 'portrait-revision');
    expect(people.last.imageTag, isNull);
    data['item']['People'][0]['Id'] = 'https://provider.example/person';
    expect(() => TedMetadataSnapshot.fromJson(data), throwsA(isA<TedFailure>()));
    data['item']['People'] = 'malformed';
    expect(() => TedMetadataSnapshot.fromJson(data), throwsA(isA<TedFailure>()));
    expect(TedMetadataSnapshot.fromJson(metadataData()).people, isEmpty);
  });

  test('person portraits use a private cache-only item image route and validate pending/invalid responses', () async {
    final now = DateTime.utc(2026, 10, 11);
    int status = 202, requests = 0;
    String mime = 'application/json';
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.2'});
        }
        requests++;
        expect(request.url.toString(), 'https://ted.example/api/client/v1/metadata/items/$itemId/images/Primary');
        expect(request.headers['Authorization'], 'Bearer ted_a_${'a' * 43}');
        return http.Response.bytes(
          [1, 2, 3],
          status,
          headers: {'x-ted-compatibility-version': '0.2', 'content-type': mime},
        );
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'u', '', 'Fixture');
    final client = TedClient(auth);
    expect(await client.personPortrait(itemId), isNull);
    status = 200;
    mime = 'image/jpeg';
    expect(await client.personPortrait(itemId), [1, 2, 3]);
    mime = 'text/html';
    await expectLater(client.personPortrait(itemId), throwsA(isA<TedFailure>()));
    status = 302;
    await expectLater(client.personPortrait(itemId), throwsA(isA<TedFailure>()));
    await expectLater(client.personPortrait('https://other.example/portrait'), throwsA(isA<TedFailure>()));
    expect(requests, 4);
  });
}
