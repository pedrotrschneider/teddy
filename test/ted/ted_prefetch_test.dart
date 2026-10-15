import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_next_preparation.dart';
import 'package:plezy/ted/ted_source_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair;
import 'ted_preparation_timeout_test.dart' show HeldPreparationClient;

const id = '11111111-1111-4111-8111-111111111111';
const media = TedMediaIdentity('episode', 'tt14976292:1:2');

class NextClient extends TedClient {
  final TedSourcePage page;
  NextClient(super.auth, this.page);
  @override
  Future<TedSourcePage> stremioSources(
    TedMediaIdentity media, {
    bool forceRefresh = false,
    String preferredAddonId = '',
    Future<void>? abortTrigger,
  }) async => page;
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
    await preparation.ready;
    expect(auth.signedIn, true);
  });
  testWidgets('next prefetch requires unique same-addon binge match and ready RD file', (tester) async {
    final now = DateTime.utc(2026, 10, 14);
    final calls = <String>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return http.Response(jsonEncode(pair(now)), 200);
        calls.add(r.url.path);
        return http.Response('{"ready":true}', 200);
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
      [choice(ready: false)],
      [choice(addon: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc')],
      [choice(), choice()],
    ]) {
      final client = NextClient(auth, TedSourcePage(false, false, choices, [], null));
      final prefetch = TedNextPreparation(client, const TedTitle(media, 'Episode', '', false, 0, 0, false), session);
      expect(await prefetch.source, isNull);
      prefetch.discard();
    }
    expect(calls, isEmpty);
    final client = NextClient(auth, TedSourcePage(false, false, [choice()], [], null));
    final prefetch = TedNextPreparation(client, const TedTitle(media, 'Episode', '', false, 0, 0, false), session);
    expect(await prefetch.source, id);
    expect(calls, ['/api/client/v1/playback/preparations']);
    expect(client.takePreparedSources(media)?.choices.single.id, id);
    prefetch.discard();
    await tester.pump();
  });
}
