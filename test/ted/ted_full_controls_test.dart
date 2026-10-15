import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/transport_keys.dart';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';
import 'ted_playback_test.dart' show ControlFixture;

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
  });
  test('explicit transport commands remain idempotent and retain rate across token recovery', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          await f.playback.transport(TransportCommand.pause);
          await f.playback.transport(TransportCommand.pause);
          expect(f.playback.wantsToPlay, false);
          await f.playback.setRate(1.5);
          f.now = f.now.add(const Duration(minutes: 11));
          await f.playback.transport(TransportCommand.play);
          await f.loaded();
          expect(f.rotations, 0);
          expect(f.playback.wantsToPlay, true);
          final speeds = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'speed');
          expect((speeds.last.arguments as Map)['value'], '1.5');
          await f.playback.transport(TransportCommand.play);
          expect(f.playback.wantsToPlay, true);
          await f.playback.stop();
          expect(f.reports.where((e) => e['kind'] == 'start').length, 1);
          expect(f.reports.where((e) => e['kind'] == 'stop').length, 1);
          expect(f.playback.failure, isNull);
        } finally {
          await f.close();
        }
      },
    );
  });
  test('a held access recovery is fenced by stop and cannot create another stream or history event', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.now = f.now.add(const Duration(minutes: 11));
          f.releaseRefresh = Completer();
          final rate = f.playback.reconnect(refreshAccess: true);
          await f.refreshEntered.future;
          final stop = f.playback.stop();
          f.releaseRefresh!.complete();
          await rate;
          await stop;
          expect(
            f.calls.where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile').length,
            1,
          );
          expect(f.reports.where((e) => e['kind'] == 'stop').length, 1);
        } finally {
          await f.close();
        }
      },
    );
  });
}
