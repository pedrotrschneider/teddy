import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_playback.dart';
import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/subtitle_fonts.dart';
import 'ted_playback_test.dart' show ControlFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(prepareSubtitleFonts);
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
  });
  test('outgoing MPV events cannot publish readiness duration or viewing for the successor', () async {
    final f = ControlFixture();
    addTearDown(f.auth.close);
    await f.auth.login('https://ted.example', 'fixture', '', 'Engine transition');
    const id = '44444444-4444-4444-8444-444444444444';
    final playback = TedPlayback(
      TedClient(f.auth),
      f.player,
      const TedPlaybackSession(
        id,
        TedMediaIdentity('episode', 'tt1234567:1:2'),
        '/api/client/v1/playback/sessions/$id/media',
        0,
        0,
        source: 'addon',
        expectedDurationMs: 100000,
      ),
    );
    final entered = Completer<void>(), release = Completer<void>();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (MethodCall call) async {
        final result = await f.method(call);
        if (call.method == 'command' && (call.arguments as Map)['args'][0] == 'loadfile') {
          f.player.handlePlayerEvent('start-file', {'sourceId': 41});
          f.player.handlePropertyChange('duration', 500.0, sourceId: 41);
          f.player.handlePlayerEvent('file-loaded', {'sourceId': 41});
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 41, 'positionSeconds': 99.0});
          entered.complete();
          await release.future;
          return {'playlistEntryId': 42};
        }
        return result;
      },
      testBody: () async {
        try {
          final opening = playback.open();
          await entered.future;
          await Future<void>.delayed(Duration.zero);
          expect(playback.ready, false);
          expect(playback.durationMs, 0);
          expect(f.reports, isEmpty);
          release.complete();
          await opening;
          expect(playback.ready, false);
          f.player.handlePlayerEvent('start-file', {'sourceId': 42});
          f.player.handlePlayerEvent('file-loaded', {'sourceId': 42});
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 42, 'positionSeconds': 0.0});
          await Future<void>.delayed(Duration.zero);
          expect(playback.durationMs, 0, reason: 'the outgoing engine snapshot is not this file duration');
          expect(f.reports, isEmpty);
          f.player.handlePropertyChange('duration', 100.0, sourceId: 42);
          await Future<void>.delayed(Duration.zero);
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 41, 'positionSeconds': 99.0});
          f.player.handlePlayerEvent('end-file', {'sourceId': 41, 'reason': 'eof'});
          await Future<void>.delayed(Duration.zero);
          await playback.flush();
          expect(playback.ready, true);
          expect(playback.durationMs, 100000);
          expect(playback.positionMs, 0);
          expect(playback.completedNaturally, false);
          expect(
            f.reports.every((r) => r['session_id'] == id && r['position_ms'] == 0 && r['kind'] != 'complete'),
            true,
          );
        } finally {
          if (!release.isCompleted) release.complete();
          await playback.closePlayer();
        }
      },
    );
  });
}
