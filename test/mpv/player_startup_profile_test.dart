import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player_native.dart';
import '../test_helpers/mock_player_channels.dart';

Future<void> withPlayer(Future<void> Function(PlayerNative, List<PlayerLog>) body, {String prefix = 'startup'}) async {
  await withMockPlayerChannels(
    methodChannelName: 'com.plezy/mpv_player',
    eventChannelName: 'com.plezy/mpv_player/events',
    testBody: () async {
      final player = PlayerNative();
      final logs = <PlayerLog>[];
      final subscription = player.streams.log.where((log) => log.prefix == prefix).listen(logs.add);
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

  Map<String, Object> detail(String phase, int source) => {
    'phase': phase,
    'sourceId': source,
    'elapsedUs': 1000000,
    'deliveryUs': 12,
    'sequence': 1,
    'url': 'https://private.invalid/secret',
    'header': 'Authorization: Bearer secret',
  };

  test('detailed first-frame tail survives restart and is fenced by source and completion', () async {
    await withPlayer((player, logs) async {
      await player.setStartupTracing(true);
      player.handlePlayerEvent('start-file', {'sourceId': 7});
      player.handlePlayerEvent('startup-detail', detail('audio_ready', 7));
      player.handlePlayerEvent('playback-restart', {'sourceId': 7, 'positionSeconds': 0.0});
      player.handlePlayerEvent('startup-detail', detail('first_video_shown', 7));
      player.handlePlayerEvent('startup-detail', {...detail('event_queue_stall', 7), 'waitUs': 750000});
      player.handlePlayerEvent('startup-detail', {...detail('audio_decoder_open', 7), 'occurrence': 1});
      player.handlePlayerEvent('startup-detail', {...detail('audio_decoder_open', 7), 'occurrence': 2});
      player.handlePlayerEvent('startup-detail', {...detail('audio_decoder_open', 7), 'occurrence': 2});
      player.handlePlayerEvent('startup-detail', {...detail('audio_decoder_open', 7), 'occurrence': 5});
      player.handlePropertyChange('aid', '2', sourceId: 7);
      player.handlePropertyChange('aid', 'https://private.invalid/secret', sourceId: 7);
      player.handlePlayerEvent('start-file', {'sourceId': 8});
      player.handlePlayerEvent('startup-detail', detail('subtitle_wait', 7));
      player.handlePlayerEvent('startup-detail', detail('audio_ready', 8));
      player.handlePlayerEvent('startup-detail', detail('trace_complete', 8));
      player.handlePlayerEvent('startup-detail', detail('video_start', 8));
      await Future<void>.delayed(Duration.zero);
      expect(logs.map((v) => v.text.split(' ').take(2).join(' ')), [
        'phase=audio_ready source=7',
        'phase=first_video_shown source=7',
        'phase=event_queue_stall source=7',
        'phase=audio_decoder_open source=7',
        'phase=audio_decoder_open source=7',
        'phase=audio_track source=7',
        'phase=audio_ready source=8',
        'phase=trace_complete source=8',
      ]);
      expect(logs.map((v) => v.text).join(), isNot(contains('secret')));
      expect(logs.any((v) => v.text.contains('queue_wait_us=750000')), true);
    }, prefix: 'startup-detail');
  });

  test('malformed detail payloads and stale/end-file cache samples cannot reach logs', () async {
    await withPlayer((player, logs) async {
      await player.setStartupTracing(true);
      player.handlePlayerEvent('start-file', {'sourceId': 7});
      for (final invalid in [-1, 90000001, double.nan, 'private']) {
        player.handlePlayerEvent('startup-detail', {...detail('audio_ready', 7), 'elapsedUs': invalid});
      }
      player.handlePlayerEvent('startup-detail', detail('https://private.invalid/secret', 7));
      player.handlePlayerEvent('startup-detail', {...detail('audio_ready', 7), 'sequence': 65});
      player.handlePlayerEvent('startup-detail', {...detail('event_queue_wait', 7), 'waitUs': 'private'});
      final cache = {'fw-bytes': 1234, 'cache-duration': 5.25, 'underrun': false, 'url': 'secret'};
      player.handlePropertyChange('demuxer-cache-state', cache, sourceId: 6);
      player.handlePropertyChange('demuxer-cache-state', cache, sourceId: 7);
      player.handlePlayerEvent('startup-detail', detail('audio_ready', 7));
      player.handlePlayerEvent('end-file', {'sourceId': 7, 'reason': 2});
      player.handlePlayerEvent('startup-detail', detail('video_start', 7));
      await Future<void>.delayed(Duration.zero);
      expect(logs.length, 2);
      expect(logs.first.text, contains('fw_bytes=1234 cache_duration_ms=5250 underrun=0'));
      expect(logs.last.text, contains('phase=audio_ready source=7'));
      expect(logs.map((v) => v.text).join(), isNot(contains('secret')));
    }, prefix: 'startup-detail');
  });

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
