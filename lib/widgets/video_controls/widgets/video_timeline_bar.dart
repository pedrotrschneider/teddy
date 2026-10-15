import 'package:flutter/material.dart';

import '../../../mpv/mpv.dart';
import '../../../media/media_source_info.dart';
import '../../../services/scrub_preview_source.dart';
import '../../../utils/formatters.dart';
import 'finish_time_builder.dart';
import 'timeline_slider.dart';
import '../player_control_scope.dart';

/// Encapsulates the StreamBuilder stack for video timeline with timestamps.
///
/// This widget listens to player position and duration streams, and displays
/// a timeline slider with formatted timestamps. Supports both horizontal
/// layout (timestamps beside slider) and vertical layout (timestamps below slider).
class VideoTimelineBar extends StatelessWidget {
  final Player player;
  final List<MediaChapter> chapters;
  final bool chaptersLoaded;
  final bool showChapterMarkersOnTimeline;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration> onSeekEnd;
  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  /// If true, timestamps are shown in a row beside the slider (desktop layout).
  /// If false, timestamps are shown in a row below the slider (mobile layout).
  final bool horizontalLayout;

  /// Optional FocusNode for D-pad/keyboard navigation.
  final FocusNode? focusNode;

  /// Custom key event handler for focus navigation.
  final KeyEventResult Function(FocusNode, KeyEvent)? onKeyEvent;

  /// Called when focus changes.
  final ValueChanged<bool>? onFocusChange;

  final bool enabled;

  /// Whether to show the estimated finish time next to the remaining timestamp (mobile).
  final bool showFinishTime;

  /// Optional callback that returns thumbnail image bytes for a given timestamp.
  final ScrubFrame? Function(Duration time)? thumbnailDataBuilder;

  /// When true, show the preview thumbnail at the current playback position
  /// (used during sustained dpad/keyboard key-repeat seeking).
  final bool showKeyRepeatThumbnail;

  /// Optional UI-only position used while a remote/keyboard seek is pending.
  final Duration? previewPosition;

  const VideoTimelineBar({
    super.key,
    required this.player,
    required this.chapters,
    required this.chaptersLoaded,
    this.showChapterMarkersOnTimeline = true,
    required this.onSeek,
    required this.onSeekEnd,
    this.onScrubStart,
    this.onScrubEnd,
    this.horizontalLayout = true,
    this.focusNode,
    this.onKeyEvent,
    this.onFocusChange,
    this.enabled = true,
    this.showFinishTime = false,
    this.thumbnailDataBuilder,
    this.showKeyRepeatThumbnail = false,
    this.previewPosition,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.streams.position,
      initialData: player.state.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: player.streams.duration,
          initialData: player.state.duration,
          builder: (context, durationSnapshot) {
            return StreamBuilder<List<BufferRange>>(
              stream: player.streams.bufferRanges,
              initialData: player.state.bufferRanges,
              builder: (context, bufferRangesSnapshot) {
                final tedPosition = PlayerTimelinePosition.of(context);
                final rawPosition = tedPosition ?? positionSnapshot.data ?? Duration.zero;
                final duration = PlayerTimelinePosition.durationOf(context) ?? durationSnapshot.data ?? Duration.zero;
                final position = previewPosition == null ? rawPosition : clampDuration(previewPosition!, duration);
                final retainedRanges = bufferRangesSnapshot.data ?? const <BufferRange>[];
                // mpv can retain disconnected cache regions after a seek. TED's
                // buffer highlight describes the region at this playhead, not
                // an old region elsewhere in the file. Do not discard the
                // native cache: returning to it may still avoid a network read.
                final bufferRanges = tedPosition == null
                    ? retainedRanges
                    : retainedRanges.where((range) => range.start <= rawPosition && range.end >= rawPosition).toList();
                final remaining = position - duration; // We want this to be negative

                return RepaintBoundary(
                  child: horizontalLayout
                      ? _buildHorizontalLayout(position, duration, remaining, bufferRanges)
                      : _buildVerticalLayout(position, duration, remaining, bufferRanges),
                );
              },
            );
          },
        );
      },
    );
  }

  static Duration clampDuration(Duration position, Duration duration) {
    if (position.isNegative) return Duration.zero;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  Widget _buildHorizontalLayout(
    Duration position,
    Duration duration,
    Duration remaining,
    List<BufferRange> bufferRanges,
  ) {
    return Row(
      children: [
        _buildTimestamp(position),
        const SizedBox(width: 12),
        Expanded(child: _buildSlider(position, duration, bufferRanges)),
        const SizedBox(width: 12),
        _buildTimestamp(remaining),
      ],
    );
  }

  Widget _buildVerticalLayout(
    Duration position,
    Duration duration,
    Duration remaining,
    List<BufferRange> bufferRanges,
  ) {
    return Column(
      children: [
        _buildSlider(position, duration, bufferRanges),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: .spaceBetween,
            children: [_buildTimestamp(position), _buildRemainingTimestamp(remaining)],
          ),
        ),
      ],
    );
  }

  static const _timestampStyle = TextStyle(
    color: Colors.white,
    fontSize: 14,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  Widget _buildTimestamp(Duration time) {
    return Text(formatDurationTimestamp(time), style: _timestampStyle);
  }

  Widget _buildRemainingTimestamp(Duration remaining) {
    if (!showFinishTime) return _buildTimestamp(remaining);
    return FinishTimeBuilder(
      player: player,
      builder: (context, finishTime) {
        if (finishTime == null) return _buildTimestamp(remaining);
        final clock = formatClockTime(finishTime, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context));
        return Text('${formatDurationTimestamp(remaining)} · $clock', style: _timestampStyle);
      },
    );
  }

  Widget _buildSlider(Duration position, Duration duration, List<BufferRange> bufferRanges) {
    return TimelineSlider(
      position: position,
      duration: duration,
      bufferRanges: bufferRanges,
      chapters: chapters,
      chaptersLoaded: chaptersLoaded,
      showChapterMarkersOnTimeline: showChapterMarkersOnTimeline,
      onSeek: onSeek,
      onSeekEnd: onSeekEnd,
      onScrubStart: onScrubStart,
      onScrubEnd: onScrubEnd,
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      onFocusChange: onFocusChange,
      enabled: enabled,
      thumbnailDataBuilder: thumbnailDataBuilder,
      showKeyRepeatThumbnail: showKeyRepeatThumbnail,
    );
  }
}
