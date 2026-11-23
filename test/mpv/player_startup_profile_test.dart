import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player_native.dart';
import '../test_helpers/mock_player_channels.dart';

Future<void> withPlayer(Future<void> Function(PlayerNative, List<PlayerLog>) body) async {
  await withMockPlayerChannels(
    methodChannelName: 'com.plezy/mpv_player',
    eventChannelName: 'com.plezy/mpv_player/events',
    testBody: () async {
      final player = PlayerNative();
      final logs = <PlayerLog>[];
      final subscription = player.streams.log.where((log) => log.prefix == 'startup').listen(logs.add);
      try {
        await body(player, logs);
      } finally {
        await subscription.cancel();
        await player.dispose();
      }
    },
  );
}

Map<String, dynamic> profile(String phase, {int source = 7, Object elapsed = 125, Object delivery = 3}) => {
  'sourceId': source,
  'phase': phase,
  'elapsedMs': elapsed,
  'deliveryMs': delivery,
  'url': 'https://private.invalid/secret',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup phases are bounded to one occurrence before the first restart for each source', () async {
    await withPlayer((player, logs) async {
      player.handlePlayerEvent('start-file', {'sourceId': 7});
      for (var i = 0; i < 100; i++) {
        player.handlePlayerEvent('startup-profile', profile('video_reconfig'));
      }
      player.handlePlayerEvent('startup-profile', profile('restart_received'));
      player.handlePlayerEvent('startup-profile', profile('restart_snapshot_done'));
      player.handlePlayerEvent('playback-restart', {'sourceId': 7, 'positionSeconds': 0.0});
      player.handlePlayerEvent('startup-profile', profile('audio_reconfig'));
      player.handlePlayerEvent('start-file', {'sourceId': 8});
      player.handlePlayerEvent('startup-profile', profile('video_reconfig', source: 8));
      await Future<void>.delayed(Duration.zero);
      expect(logs.map((log) => log.text), [
        'phase=video_reconfig source=7 native_elapsed_ms=125 delivery_ms=3',
        'phase=restart_received source=7 native_elapsed_ms=125 delivery_ms=3',
        'phase=restart_snapshot_done source=7 native_elapsed_ms=125 delivery_ms=3',
        'phase=video_reconfig source=8 native_elapsed_ms=125 delivery_ms=3',
      ]);
    });
  });

  test('late outgoing events cannot profile or close the successor startup', () async {
    await withPlayer((player, logs) async {
      player.handlePlayerEvent('startup-profile', profile('start_file'));
      player.handlePlayerEvent('start-file', {'sourceId': 7});
      player.handlePlayerEvent('start-file', {'sourceId': 8});
      player.handlePlayerEvent('startup-profile', profile('file_loaded'));
      player.handlePlayerEvent('end-file', {'sourceId': 7, 'reason': 2});
      player.handlePlayerEvent('startup-profile', profile('file_loaded', source: 8));
      player.handlePlayerEvent('end-file', {'sourceId': 8, 'reason': 2});
      player.handlePlayerEvent('startup-profile', profile('audio_reconfig', source: 8));
      await Future<void>.delayed(Duration.zero);
      expect(logs.single.text, 'phase=file_loaded source=8 native_elapsed_ms=125 delivery_ms=3');
    });
  });

  test('unrecognized phases and malformed timings never enter the diagnostic log', () async {
    await withPlayer((player, logs) async {
      player.handlePlayerEvent('start-file', {'sourceId': 7});
      player.handlePlayerEvent('startup-profile', profile('https://private.invalid/secret'));
      for (final invalid in [-1, 600001, double.nan, double.infinity, 'secret']) {
        player.handlePlayerEvent('startup-profile', profile('file_loaded', elapsed: invalid));
        player.handlePlayerEvent('startup-profile', profile('file_loaded', delivery: invalid));
      }
      player.handlePlayerEvent('startup-profile', profile('file_loaded'));
      await Future<void>.delayed(Duration.zero);
      expect(logs.single.text, 'phase=file_loaded source=7 native_elapsed_ms=125 delivery_ms=3');
      expect(logs.single.level, PlayerLogLevel.info);
    });
  });
}
