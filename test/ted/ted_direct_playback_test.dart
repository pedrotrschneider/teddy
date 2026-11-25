import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_media_transport.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_playback.dart';
import 'package:plezy/ted/ted_player_engine.dart';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/subtitle_fonts.dart';
import 'ted_playback_test.dart' show ControlFixture;

class Transport implements TedMediaTransport {
  final String name;
  int closes = 0;
  Transport(this.name);
  @override
  Future<Uri> open() async => Uri.parse('http://127.0.0.1:32145/$name');
  @override
  void resume() {}
  @override
  Future<void> close() async {
    closes++;
  }
}

TedPlaybackSession session(String id, int episode) => TedPlaybackSession(
  id,
  TedMediaIdentity('episode', 'tt1234567:1:$episode'),
  '/api/client/v1/playback/sessions/$id/media',
  100000,
  0,
);
const oldSession = '33333333-3333-4333-8333-333333333333';
const nextSession = '44444444-4444-4444-8444-444444444444';
Future<void> settle() => Future<void>.delayed(Duration.zero);

void started(ControlFixture f, int source) {
  f.player.handlePlayerEvent('start-file', {'sourceId': source});
  f.player.handlePlayerEvent('file-loaded', {'sourceId': source});
  f.player.handlePlayerEvent('playback-restart', {'sourceId': source, 'positionSeconds': 0.0});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(prepareSubtitleFonts);
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
  });

  test('prepared replacement retains transport until new START_FILE and fences outgoing errors and viewing', () async {
    final f = ControlFixture();
    final oldTransport = Transport('old'), nextTransport = Transport('next');
    final pool = TedPlayerEnginePool(create: (_, _) => f.player);
    final incomingLoad = Completer<void>(), acceptIncoming = Completer<void>();
    var loads = 0;
    late TedPlayback old;
    TedPlayback? next;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        final result = await f.method(call);
        if (call.method == 'command' && ((call.arguments as Map)['args'] as List).first == 'loadfile') {
          final source = ++loads;
          if (source == 2) {
            incomingLoad.complete();
            await acceptIncoming.future;
          }
          return {'playlistEntryId': source};
        }
        return result;
      },
      testBody: () async {
        await f.auth.login('https://ted.example', 'fixture', '', 'Replacement fixture');
        await pool.acquire('profile', exo: false, hardware: true);
        old = TedPlayback(
          TedClient(f.auth),
          f.player,
          session(oldSession, 2),
          mediaTransport: oldTransport,
          releasePlayer: (p) => pool.release(p, retain: true),
          releaseForReplacement: pool.releaseForReplacement,
        );
        try {
          await old.open();
          started(f, 1);
          await settle();
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 1, 'positionSeconds': 17.0});
          await settle();
          expect(old.armDirectReplacement(), true);
          await old.stop(markWatched: true);
          final retiring = old.closePlayer();
          await settle();
          expect(oldTransport.closes, 0);
          final engine = await pool.acquire('profile', exo: false, hardware: true);
          expect(engine, same(f.player));
          next = TedPlayback(
            TedClient(f.auth),
            engine,
            session(nextSession, 3),
            mediaTransport: nextTransport,
            retiringSourceId: pool.replacingSourceId(engine),
            releasePlayer: (p) => pool.release(p, retain: false),
          );
          final opening = next!.open();
          await incomingLoad.future;
          f.player.handlePlayerEvent('end-file', {'sourceId': 1, 'reason': 4, 'message': 'HTTP error 401'});
          f.player.handlePlayerEvent('log-message', {'prefix': 'ffmpeg', 'level': 'warn', 'text': 'HTTP error 401'});
          f.player.handlePlayerEvent('end-file', {'sourceId': 1, 'reason': 0});
          await settle();
          expect(f.rotations, 0);
          expect(next!.failure, isNull);
          expect(next!.completedNaturally, false);
          expect(oldTransport.closes, 0);
          f.player.handlePlayerEvent('start-file', {'sourceId': 2});
          await settle();
          await retiring;
          expect(oldTransport.closes, 1);
          acceptIncoming.complete();
          await opening;
          f.player.handlePlayerEvent('file-loaded', {'sourceId': 2});
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 2, 'positionSeconds': 0.0});
          await settle();
          f.player.handlePlayerEvent('end-file', {'sourceId': 1, 'reason': 4, 'message': 'HTTP error 401'});
          f.player.handlePropertyChange('time-pos', 99.0, sourceId: 1);
          await settle();
          expect(next!.ready, true);
          expect(next!.hasFirstFrame, true);
          expect(next!.positionMs, 0);
          expect(next!.failure, isNull);
          expect(f.rotations, 0);
          expect(loads, 2);
          expect(f.reports.where((e) => e['session_id'] == oldSession && e['kind'] == 'complete'), hasLength(1));
          // A zero-position start receipt is legitimate. Outgoing progress or
          // EOF must not turn it into qualified viewing or completion.
          final nextReports = f.reports.where((e) => e['session_id'] == nextSession).toList();
          expect(nextReports, hasLength(1));
          expect(nextReports.single['kind'], 'start');
          expect(nextReports.single['position_ms'], 0);
          expect(nextReports.single['natural_eof'], false);
          expect(
            f.calls.where((c) => c.method == 'command' && ((c.arguments as Map)['args'] as List).first == 'stop'),
            isEmpty,
          );
          await next!.closePlayer();
          expect(nextTransport.closes, 1);
        } finally {
          if (!acceptIncoming.isCompleted) acceptIncoming.complete();
          old.cancelDirectReplacement();
          await pool.cancelReplacement();
          await old.closePlayer();
          await next?.closePlayer();
          await pool.close();
          f.auth.close();
        }
      },
    );
  });

  test('a rejected pause falls back to ordinary retirement and closes the transport', () async {
    final f = ControlFixture();
    final transport = Transport('fallback');
    var direct = false, normal = false;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        final result = await f.method(call);
        if (call.method == 'command' && ((call.arguments as Map)['args'] as List).first == 'loadfile') {
          return {'playlistEntryId': 1};
        }
        return result;
      },
      testBody: () async {
        await f.auth.login('https://ted.example', 'fixture', '', 'Pause fallback fixture');
        final playback = TedPlayback(
          TedClient(f.auth),
          f.player,
          session(oldSession, 2),
          mediaTransport: transport,
          releaseForReplacement: (_, _) async {
            direct = true;
          },
          releasePlayer: (p) async {
            normal = true;
            await p.dispose();
          },
        );
        try {
          await playback.open();
          started(f, 1);
          await settle();
          expect(playback.armDirectReplacement(), true);
          f.rejectPause = true;
          await playback.stop(markWatched: true);
          expect(transport.closes, 1);
          await playback.closePlayer();
          expect(normal, true);
          expect(direct, false);
        } finally {
          playback.cancelDirectReplacement();
          await playback.closePlayer();
          await f.player.dispose();
          f.auth.close();
        }
      },
    );
  });
}
