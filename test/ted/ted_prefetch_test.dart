import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_next_preparation.dart';
import 'package:plezy/ted/ted_source_models.dart';
import 'package:plezy/models/next_episode_matching_strategy.dart';
import 'ted_auth_test.dart' show MemoryStore, pair;
import 'ted_preparation_timeout_test.dart' show HeldPreparationClient;

const id = '11111111-1111-4111-8111-111111111111';
const media = TedMediaIdentity('episode', 'tt14976292:1:2');

class NextClient extends TedClient {
  TedSourcePage page;
  TedSourcePage mapping = const TedSourcePage(true, true, [], [], null);
  TedFailure? sourceFailure;
  TedFailure? cacheSessionFailure;
  int cacheSessionRequests = 0;
  final refreshes = <bool>[];
  NextClient(super.auth, this.page);
  @override
  Future<TedSourcePage> stremioSources(
    TedMediaIdentity media, {
    bool forceRefresh = false,
    String preferredAddonId = '',
    Future<void>? abortTrigger,
  }) async {
    refreshes.add(forceRefresh);
    if (sourceFailure != null) throw sourceFailure!;
    return page;
  }

  @override
  Future<TedSourcePage> mappedSource(TedMediaIdentity media) async => mapping;

  @override
  Future<TedPlaybackSession> createCacheSession(
    TedMediaIdentity media, {
    String? sourceId,
    Future<void>? abortTrigger,
  }) async {
    cacheSessionRequests++;
    final failure = cacheSessionFailure;
    cacheSessionFailure = null;
    if (failure != null) throw failure;
    return TedPlaybackSession(
      '33333333-3333-4333-8333-333333333333',
      media,
      '',
      100000,
      0,
      source: sourceId == null ? 'mapped_rd' : 'addon',
    );
  }
}

void main() {
  testWidgets('abandoning pending preparation aborts it without signing out', (tester) async {
    final now = DateTime.utc(2026, 10, 14);
    final wire = HeldPreparationClient(now);
    final auth = TedAuth(store: MemoryStore(), client: wire, now: () => now);
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = TedClient(auth);
    final preparation = client.prepareSource(media, id);
    await tester.pump();
    client.discardPreparation(preparation);
    await tester.pump();
    expect(wire.aborted, contains('/api/client/v1/playback/preparations'));
    final deletion = '/api/client/v1/playback/preparations/$id';
    wire.calls[deletion]!.complete(wire.reply({'discarded': true}));
    await tester.pump();
    await expectLater(preparation.ready, throwsA(isA<TedFailure>()));
    expect(auth.signedIn, true);
  });
  testWidgets('next prefetch pins a unique same-addon binge match and requests its missing exact RD file', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 10, 14);
    final calls = <String>[];
    final bodies = <Map<String, dynamic>>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
        }
        calls.add(r.url.path);
        if (r.method == 'POST') {
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
        }
        return http.Response('{"ready":true}', 200, headers: {'x-ted-compatibility-version': '0.3'});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final session = TedPlaybackSession.fromJson({
      'id': '33333333-3333-4333-8333-333333333333',
      'media': {'kind': 'episode', 'id': 'tt14976292:1:1'},
      'media_url': '/api/client/v1/playback/sessions/33333333-3333-4333-8333-333333333333/media',
      'audio_languages': ['en'],
      'source': 'addon',
      'duration_ms': 100000,
      'resume_ms': 0,
      'watch_revision': 0,
      'addon_id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'binge_key': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    }, const TedMediaIdentity('episode', 'tt14976292:1:1'));
    TedSourceChoice choice({bool ready = true, String? addon}) => TedSourceChoice(
      id,
      'Addon',
      'Release',
      '',
      addonId: addon ?? session.addonId,
      bingeKey: session.bingeKey,
      rdDirectPlay: true,
      inRDAccount: ready,
    );
    for (final choices in [
      [choice(addon: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc')],
      [choice(), choice()],
    ]) {
      final client = NextClient(auth, TedSourcePage(false, false, choices, [], null));
      final prefetch = TedNextPreparation(client, const TedTitle(media, 'Episode', '', false, 0, 0, false), session);
      expect(await prefetch.source, isNull);
      prefetch.discard();
    }
    expect(calls, isEmpty);
    final client = NextClient(auth, TedSourcePage(false, false, [choice(ready: false)], [], null));
    final prefetch = TedNextPreparation(client, const TedTitle(media, 'Episode', '', false, 0, 0, false), session);
    expect(await prefetch.source, id);
    expect(calls, ['/api/client/v1/playback/preparations']);
    expect(bodies.single['allow_add'], true);
    expect(client.takePreparedSources(media)?.choices.single.id, id);
    prefetch.discard();
    await tester.pump();
  });

  testWidgets('no match refreshes the provider after one minute and preserves the sources for details', (tester) async {
    final now = DateTime.utc(2026, 11, 20);
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(r.url.path.endsWith('/login') ? pair(now) : {'ready': true}),
          200,
          headers: {'x-ted-compatibility-version': '0.3'},
        ),
      ),
      now: () => now,
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final current = TedPlaybackSession(
      'session',
      const TedMediaIdentity('episode', 'tt14976292:1:1'),
      '',
      100000,
      0,
      source: 'addon',
      addonId: 'addon',
      bingeKey: 'group',
    );
    final client = NextClient(auth, const TedSourcePage(false, false, [], [], null));
    final work = TedNextPreparation(client, const TedTitle(media, 'Episode', '', false, 0, 0, false), current);
    await tester.pump();
    expect(await work.source, isNull);
    expect(work.phase, TedNextPhase.retrying);
    expect(client.takePreparedSources(media)?.choices, isEmpty);
    client.page = const TedSourcePage(
      false,
      false,
      [TedSourceChoice(id, 'Addon', 'Release', '', addonId: 'addon', bingeKey: 'group', rdDirectPlay: true)],
      [],
      null,
    );
    await tester.pump(const Duration(seconds: 59));
    expect(client.refreshes, [false]);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(await work.source, id);
    expect(client.refreshes, [false, true]);
    expect(work.phase, TedNextPhase.ready);
    work.discard();
    await tester.pump();
  });
  testWidgets('server failures retry the pinned choice and device failures retry only caching', (tester) async {
    final now = DateTime.utc(2026, 11, 20);
    var warm = 0, cache = 0;
    final operations = <String>[];
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
        }
        if (r.method == 'POST') {
          warm++;
          operations.add((jsonDecode(r.body) as Map)['operation_id'] as String);
        }
        return http.Response(
          jsonEncode(warm == 1 ? {'code': 'rd_source_pending'} : {'ready': true}),
          warm == 1 ? 409 : 200,
          headers: {'x-ted-compatibility-version': '0.3'},
        );
      }),
      now: () => now,
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = NextClient(
      auth,
      const TedSourcePage(
        false,
        false,
        [TedSourceChoice(id, 'Addon', 'Release', '', addonId: 'addon', bingeKey: 'group', rdDirectPlay: true)],
        [],
        null,
      ),
    );
    final current = TedPlaybackSession(
      'session',
      const TedMediaIdentity('episode', 'tt14976292:1:1'),
      '',
      100000,
      0,
      source: 'addon',
      addonId: 'addon',
      bingeKey: 'group',
    );
    final work = TedNextPreparation(
      client,
      const TedTitle(media, 'Episode', '', false, 0, 0, false),
      current,
      cache: (_) async {
        cache++;
        if (cache == 1) throw const TedFailure('unavailable');
      },
    );
    await tester.pump();
    expect(await work.source, isNull);
    expect(cache, 0);
    expect(warm, 1);
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(await work.source, isNull);
    expect(warm, 2);
    expect(cache, 1);
    expect(work.serverReady, true);
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(await work.source, id);
    expect(warm, 2);
    expect(cache, 2);
    expect(operations.toSet(), hasLength(1));
    expect(client.refreshes, [false]);
    work.discard();
    await tester.pump(const Duration(minutes: 2));
    expect(warm, 2);
    expect(cache, 2);
  });
  testWidgets('mapped playback ignores add-on lookup failure and never substitutes an unmapped successor', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 11, 20);
    final calls = <String>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
        }
        calls.add(r.url.path);
        return http.Response('{"ready":true}', 200, headers: {'x-ted-compatibility-version': '0.3'});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = NextClient(
      auth,
      const TedSourcePage(
        false,
        false,
        [TedSourceChoice(id, 'Addon', 'Release', '', addonId: 'addon', bingeKey: 'group', rdDirectPlay: true)],
        [],
        null,
      ),
    )..sourceFailure = const TedFailure('unavailable');
    final current = TedPlaybackSession(
      'session',
      const TedMediaIdentity('episode', 'tt14976292:1:1'),
      '',
      100000,
      0,
      source: 'mapped_rd',
    );
    var warm = 0;
    final mapped = TedNextPreparation(
      client,
      const TedTitle(media, 'Episode', '', false, 0, 0, false),
      current,
      serverWarm: (_) async {
        warm++;
      },
    );
    await mapped.serverPrepared;
    expect(mapped.serverReady, true);
    expect(mapped.mapped, true);
    expect(warm, 1);
    mapped.discard();
    client.sourceFailure = null;
    client.mapping = const TedSourcePage(false, false, [], [], null);
    final unmapped = TedNextPreparation(
      client,
      const TedTitle(media, 'Episode', '', false, 0, 0, false),
      current,
      serverWarm: (_) async {
        warm++;
      },
    );
    await unmapped.serverPrepared;
    expect(unmapped.serverReady, false);
    expect(unmapped.phase, TedNextPhase.details);
    expect(warm, 1);
    expect(calls, isEmpty);
    expect(client.takePreparedSources(media)?.choices.single.id, id);
    unmapped.discard();
  });
  testWidgets('Next can hand off a verified file while device cache fill is still held', (tester) async {
    final now = DateTime.utc(2026, 11, 20);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient(
        (_) async => http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'}),
      ),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = NextClient(auth, const TedSourcePage(false, false, [], [], null));
    var caching = false;
    final held = Completer<void>();
    final work = TedNextPreparation(
      client,
      const TedTitle(media, 'Episode', '', false, 0, 0, false),
      TedPlaybackSession(
        'session',
        const TedMediaIdentity('episode', 'tt14976292:1:1'),
        '',
        100000,
        0,
        source: 'mapped_rd',
      ),
      serverWarm: (_) async {},
      cache: (work) async {
        caching = true;
        await Future.any([held.future, work.aborted]);
      },
    );
    await tester.pump();
    await work.serverPrepared;
    expect(work.serverReady, true);
    expect(caching, true);
    expect(work.phase, TedNextPhase.caching);
    work.handoff();
    expect(await work.source, isNull);
    work.discard();
  });
  testWidgets('longer Retry-After delays govern both server and device retries', (tester) async {
    final now = DateTime.utc(2026, 11, 20);
    var warm = 0, cache = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
        }
        if (r.method == 'POST') warm++;
        return http.Response(
          jsonEncode(warm == 1 ? {'code': 'rd_limited'} : {'ready': true}),
          warm == 1 ? 429 : 200,
          headers: {'x-ted-compatibility-version': '0.3', 'retry-after': '125'},
        );
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = NextClient(
      auth,
      const TedSourcePage(
        false,
        false,
        [TedSourceChoice(id, 'Addon', 'Release', '', addonId: 'addon', bingeKey: 'group', rdDirectPlay: true)],
        [],
        null,
      ),
    );
    final current = TedPlaybackSession(
      'session',
      const TedMediaIdentity('episode', 'tt14976292:1:1'),
      '',
      100000,
      0,
      source: 'addon',
      addonId: 'addon',
      bingeKey: 'group',
    );
    final work = TedNextPreparation(
      client,
      const TedTitle(media, 'Episode', '', false, 0, 0, false),
      current,
      cache: (_) async {
        cache++;
        if (cache == 1) throw const TedFailure('rate_limited', retryAfter: Duration(seconds: 185));
      },
    );
    await tester.pump();
    expect(await work.source, isNull);
    await tester.pump(const Duration(seconds: 124));
    expect(warm, 1);
    expect(cache, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(warm, 2);
    expect(cache, 1);
    await tester.pump(const Duration(seconds: 184));
    expect(cache, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(cache, 2);
    expect(warm, 2);
    expect(work.phase, TedNextPhase.ready);
    work.discard();
    await tester.pump();
  });
  testWidgets('a lost server warm entry is revalidated instead of retrying a stale successful future', (tester) async {
    final now = DateTime.utc(2026, 11, 20);
    var warms = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
        }
        if (r.method == 'POST') warms++;
        return http.Response('{"ready":true}', 200, headers: {'x-ted-compatibility-version': '0.3'});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = NextClient(
      auth,
      const TedSourcePage(
        false,
        false,
        [TedSourceChoice(id, 'Addon', 'Release', '', addonId: 'addon', bingeKey: 'group', rdDirectPlay: true)],
        [],
        null,
      ),
    )..cacheSessionFailure = const TedFailure('source_preparation_unavailable');
    final current = TedPlaybackSession(
      'session',
      const TedMediaIdentity('episode', 'tt14976292:1:1'),
      '',
      100000,
      0,
      source: 'addon',
      addonId: 'addon',
      bingeKey: 'group',
    );
    final work = TedNextPreparation(
      client,
      const TedTitle(media, 'Episode', '', false, 0, 0, false),
      current,
      cache: (_) async {},
    );
    await tester.pump();
    expect(await work.source, isNull);
    expect(work.serverReady, false);
    expect(warms, 1);
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(await work.source, id);
    expect(warms, 2);
    expect(client.cacheSessionRequests, 2);
    expect(client.refreshes, [false]);
    expect(work.serverReady, true);
    work.discard();
    await tester.pump();
  });
  testWidgets('Manual only fetches sources and details cannot cancel another owner preparation', (tester) async {
    final now = DateTime.utc(2026, 11, 20);
    final calls = <String>[];
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
        }
        calls.add(r.method);
        return http.Response('{"ready":true}', 200, headers: {'x-ted-compatibility-version': '0.3'});
      }),
      now: () => now,
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = NextClient(auth, const TedSourcePage(false, false, [], [], null));
    final current = TedPlaybackSession('session', const TedMediaIdentity('episode', 'tt14976292:1:1'), '', 100000, 0);
    final manual = TedNextPreparation(
      client,
      const TedTitle(media, 'Episode', '', false, 0, 0, false),
      current,
      strategy: NextEpisodeMatchingStrategy.manual,
    );
    await tester.pump();
    expect(await manual.source, isNull);
    expect(calls, isEmpty);
    expect(client.takePreparedSources(media), isNotNull);
    manual.discard();
    final playing = client.prepareSource(media, id);
    final details = client.prepareSource(media, id);
    await tester.pump();
    expect(calls, ['POST']);
    client.discardPreparation(details);
    await tester.pump();
    expect(calls, ['POST']);
    await playing.ready;
    client.discardPreparation(playing);
    await tester.pump();
    expect(calls, ['POST', 'DELETE']);
  });
  testWidgets('playback preparation can add a missing file even when details owns a ready-only attempt', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 11, 20);
    final bodies = <Map<String, dynamic>>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) {
          return http.Response(jsonEncode(pair(now)), 200, headers: {'x-ted-compatibility-version': '0.3'});
        }
        if (r.method == 'POST') bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response('{"ready":true}', 200, headers: {'x-ted-compatibility-version': '0.3'});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = TedClient(auth);
    final details = client.prepareSource(media, id);
    await details.ready;
    final next = client.prepareSource(media, id, allowAdd: true);
    await next.ready;
    expect(identical(next, details), false);
    expect(bodies.map((body) => body['allow_add']), [null, true]);
    expect(bodies.map((body) => body['operation_id']).toSet(), hasLength(2));
    client.discardPreparation(details);
    client.discardPreparation(next);
    await tester.pump();
  });
}
