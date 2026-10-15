import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/widgets/video_controls/player_control_scope.dart';
import 'package:plezy/widgets/video_controls/widgets/video_timeline_bar.dart';
import 'package:plezy/widgets/video_controls/widgets/timeline_slider.dart';
import '../test_helpers/mock_player_channels.dart';
import 'ted_playback_test.dart' show ControlFixture;

void main() {
  testWidgets('backward seek stops painting the old cache region immediately and shows the new region', (tester) async {
    final f = ControlFixture();
    final position = ValueNotifier(const Duration(seconds: 80));
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          f.player.handlePropertyChange('duration', 100.0);
          f.player.handlePropertyChange('demuxer-cache-state', {
            'seekable-ranges': [
              {'start': 75, 'end': 95},
            ],
          });
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PlayerTimelinePosition(
                  position: position,
                  child: VideoTimelineBar(
                    player: f.player,
                    chapters: const [],
                    chaptersLoaded: true,
                    onSeek: (_) {},
                    onSeekEnd: (_) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          List<BufferRange> painted() => tester.widget<TimelineSlider>(find.byType(TimelineSlider)).bufferRanges;
          expect(painted().single.start, const Duration(seconds: 75));
          position.value = const Duration(seconds: 20);
          await tester.pump();
          expect(painted(), isEmpty);
          expect(
            f.player.state.bufferRanges,
            hasLength(1),
            reason: 'Presentation must not flush still-valid native cache',
          );
          f.player.handlePropertyChange('demuxer-cache-state', {
            'seekable-ranges': [
              {'start': 20, 'end': 35},
              {'start': 75, 'end': 95},
            ],
          });
          await tester.pump();
          await tester.pump();
          expect(painted(), [const BufferRange(start: Duration(seconds: 20), end: Duration(seconds: 35))]);
          f.player.handlePropertyChange('demuxer-cache-state', {'seekable-ranges': []});
          await tester.pump();
          await tester.pump();
          expect(painted(), isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() => f.player.dispose());
          position.dispose();
          f.auth.close();
        }
      },
    );
  });

  testWidgets('a seek inside retained cache keeps its highlight and upstream timelines retain all ranges', (
    tester,
  ) async {
    final f = ControlFixture();
    final position = ValueNotifier(const Duration(seconds: 85));
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          f.player.handlePropertyChange('duration', 100.0);
          f.player.handlePropertyChange('demuxer-cache-state', {
            'seekable-ranges': [
              {'start': 10, 'end': 30},
              {'start': 75, 'end': 95},
            ],
          });
          Widget bar() => VideoTimelineBar(
            player: f.player,
            chapters: const [],
            chaptersLoaded: true,
            onSeek: (_) {},
            onSeekEnd: (_) {},
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PlayerTimelinePosition(position: position, child: bar()),
              ),
            ),
          );
          await tester.pumpAndSettle();
          position.value = const Duration(seconds: 80);
          await tester.pump();
          expect(
            tester.widget<TimelineSlider>(find.byType(TimelineSlider)).bufferRanges.single.start,
            const Duration(seconds: 75),
          );
          await tester.pumpWidget(MaterialApp(home: Scaffold(body: bar())));
          await tester.pumpAndSettle();
          expect(tester.widget<TimelineSlider>(find.byType(TimelineSlider)).bufferRanges, hasLength(2));
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() => f.player.dispose());
          position.dispose();
          f.auth.close();
        }
      },
    );
  });
}
