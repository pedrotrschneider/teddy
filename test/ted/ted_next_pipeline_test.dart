import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_next_device.dart';
import 'package:plezy/ted/ted_next_preparation.dart';
import '../test_helpers/prefs.dart';
import 'ted_auth_test.dart' show MemoryStore, pair;

const nextMedia = TedMediaIdentity('episode', 'tt2560140:4:3');
const target = TedTitle(nextMedia, 'Next episode', '', false, 0, 0, false);
const current = TedPlaybackSession(
  '11111111-1111-4111-8111-111111111111',
  TedMediaIdentity('episode', 'tt2560140:4:2'),
  '',
  1400000,
  0,
  source: 'mapped_rd',
);

class PipelineFixture {
  late final TedAuth auth;
  late final TedClient client;
  late final TedNextDevicePreparation device;
  int sessions = 0, plans = 0, rdPreparations = 0;
  Completer<http.Response>? heldPlan;
  final String failure;
  final int status;
  PipelineFixture({this.failure = 'source_unsupported', this.status = 422}) {
    final now = DateTime.utc(2026, 11, 23);
    auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return reply(pair(now));
        if (request.url.path.endsWith('/sources')) {
          final input = jsonDecode(request.body) as Map;
          return reply({
            'media': nextMedia.toJson(),
            'mode': input['provider'] == 'mapped' ? 'mapped' : 'addons',
            'mapped_ready': input['provider'] == 'mapped',
            'sources': [],
            'issues': [],
          });
        }
        if (request.url.path.endsWith('/sessions')) {
          sessions++;
          final id = sessions == 1 ? '22222222-2222-4222-8222-222222222222' : '33333333-3333-4333-8333-333333333333';
          return reply({
            'id': id,
            'media': nextMedia.toJson(),
            'media_url': '/api/client/v1/playback/sessions/$id/media',
            'duration_ms': 1400000,
            'resume_ms': 0,
            'watch_revision': 0,
            'source': 'mapped_rd',
            'audio_languages': ['en'],
          }, 201);
        }
        if (request.url.path.endsWith('/cache-plan')) {
          plans++;
          if (heldPlan != null) return heldPlan!.future;
          return reply({'code': failure}, status);
        }
        if (request.url.path.endsWith('/preparations')) rdPreparations++;
        throw StateError('Unexpected API request: ${request.method} ${request.url.path}');
      }),
    );
    client = TedClient(auth);
    device = TedNextDevicePreparation(client, () async => (64 << 20, 32 << 20));
  }
  http.Response reply(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'x-ted-compatibility-version': '0.3'});
  Future<void> login() => auth.login('https://ted.example', 'fixture', '', 'Mapped Next regression');
  TedNextPreparation prepare() => TedNextPreparation(client, target, current, cache: device.preCache);
  void close() {
    device.discard();
    if (heldPlan != null && !heldPlan!.isCompleted) heldPlan!.complete(reply({'code': failure}, status));
    auth.close();
  }
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });
  for (final failure in ['source_unsupported', 'next_cache_unavailable']) {
    testWidgets('a ready RD mapping remains eligible for Next when cache planning returns $failure', (tester) async {
      final f = PipelineFixture(failure: failure, status: failure == 'source_unsupported' ? 422 : 503);
      addTearDown(f.close);
      await f.login();
      final work = f.prepare();
      addTearDown(work.discard);
      await tester.pump();
      await work.source;
      expect(f.plans, 1);
      expect(work.mapped, true);
      expect(work.serverReady, true, reason: 'optional cache planning must not veto a verified mapping');
      expect(work.phase, TedNextPhase.retrying);
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(f.plans, 2);
      expect(f.sessions, 1, reason: 'cache retries retain the prepared exact source');
      work.handoff();
      final viewing = await f.client.createSelectedSession(nextMedia);
      expect(viewing.media, nextMedia);
      expect(viewing.source, 'mapped_rd');
      expect(f.sessions, 2, reason: 'Next authorizes a fresh viewing session');
      expect(f.device.take(viewing), isNull);
      expect(f.rdPreparations, 0);
    });
  }
  testWidgets('Next can use a ready mapped session while packet planning is still pending', (tester) async {
    final f = PipelineFixture()..heldPlan = Completer<http.Response>();
    addTearDown(f.close);
    await f.login();
    final work = f.prepare();
    addTearDown(work.discard);
    await tester.pump();
    expect(f.plans, 1);
    expect(work.serverReady, true);
    var prepared = false;
    unawaited(work.serverPrepared.then((_) => prepared = true));
    await tester.pump();
    expect(prepared, true);
    work.handoff();
    final viewing = await f.client.createSelectedSession(nextMedia);
    expect(viewing.source, 'mapped_rd');
    expect(f.sessions, 2);
    // Release the held fixture response after proving Next did not await it.
    f.heldPlan!.complete(f.reply({'code': f.failure}, f.status));
    await work.source;
    await tester.pump();
  });
  for (final code in ['source_selection_required', 'source_placeholder']) {
    testWidgets('$code still invalidates mapped continuation', (tester) async {
      final f = PipelineFixture(failure: code, status: code == 'source_selection_required' ? 409 : 422);
      addTearDown(f.close);
      await f.login();
      final work = f.prepare();
      addTearDown(work.discard);
      await tester.pump();
      await work.source;
      expect(work.serverReady, false);
      expect(work.phase, TedNextPhase.blocked);
    });
  }
}
