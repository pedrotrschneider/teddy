part of '../video_controls.dart';

extension _PlexVideoControlsNavigationMethods on _PlexVideoControlsState {
  Widget _buildDesktopControlsListener() {
    final playbackState = context.watch<PlaybackStateProvider>();
    final trackControlsState = _buildTrackControlsState(
      playbackState: playbackState,
      onToggleAlwaysOnTop: Platform.isMacOS ? null : _toggleAlwaysOnTop,
    );
    final useDpad = playerDirectionalNavigationEnabled();

    return _holdChromeWhilePressed(
      child: DesktopVideoControls(
        key: _desktopControlsKey,
        skipMarkerButton: _showControls && _isSkipMarkerButtonVisible ? _buildSkipMarkerButton() : null,
        player: widget.player,
        volumeController: widget.volumeController,
        metadata: widget.metadata,
        onNext: _abandoningBurst(widget.onNext),
        onPrevious: _abandoningBurst(widget.onPrevious),
        onPlayPause: () => unawaited(_playOrPause()),
        chapters: _chapters,
        chaptersLoaded: _chaptersLoaded,
        showChapterMarkersOnTimeline: _showChapterMarkersOnTimeline,
        seekTimeSmall: _seekTimeSmall,
        onSeekToPreviousChapter: _seekToPreviousChapter,
        onSeekToNextChapter: _seekToNextChapter,
        onSeekBackward: () => unawaited(_seekByTime(forward: false)),
        onSeekForward: () => unawaited(_seekByTime(forward: true)),
        onSeek: _throttledSeek,
        onSeekEnd: _finalizeSeek,
        onScrubStart: _holdTimelineScrub,
        onScrubEnd: _releaseTimelineScrub,
        onSeekRequested: widget.onSeekRequested,
        getReplayIcon: getReplayIcon,
        getForwardIcon: getForwardIcon,
        onFocusActivity: _restartHideTimerForCurrentPlaybackState,
        onTimelineSeekFeedback: widget.metadata.backend == MediaBackend.ted
            ? (seconds) => widget.toastController.show(
                seconds < 0 ? Icons.replay : Icons.forward_10,
                '${seconds >= 0 ? '+' : ''}$seconds s',
              )
            : null,
        onHideControls: _hideControlsFromKeyboard,
        trackControlsState: trackControlsState,
        onBack: widget.onBack,
        hasFirstFrame: widget.hasFirstFrame,
        thumbnailDataBuilder: widget.thumbnailDataBuilder,
        liveChannelName: widget.liveChannelName,
        captureBuffer: widget.captureBuffer,
        isAtLiveEdge: widget.isAtLiveEdge,
        liveEpochForPosition: widget.liveEpochForPosition,
        onLiveSeek: _liveSeekAbandoningBurst(widget.onLiveSeek),
        onLiveSeekBy: widget.onLiveSeekBy,
        onJumpToLive: _abandoningBurst(widget.onJumpToLive),
        useDpadNavigation: useDpad,
        serverId: widget.metadata.serverId,
        showQueueTab: playbackState.isQueueActive && widget.canNavigateMediaItems,
        onQueueItemSelected: playbackState.isQueueActive && widget.canNavigateMediaItems ? _onQueueItemSelected : null,
        onCancelAutoHide: widget.chromeController.cancelAutoHide,
        onStartAutoHide: _startHideTimer,
        onSeekCompleted: widget.onSeekCompleted,
        onContentStripVisibilityChanged: (visible) {
          widget.chromeController.setContentStripVisible(visible);
        },
        chromeController: widget.chromeController,
      ),
    );
  }

  void _onQueueItemSelected(MediaItem item) {
    // Same contract as next/previous: the switch is asynchronous, so a burst
    // still armed here would debounce into a seek on the outgoing item.
    _hiddenSeek.cancel();
    _desktopControlsKey.currentState?.abandonPendingSeek();
    _dismissSkipFeedback();
    widget.onQueueItemSelected?.call(item);
  }

  /// Request a version, quality preset, audio stream, or source subtitle reload.
  /// The owning player screen decides how to apply it so controls do not own
  /// player lifecycle/navigation policy.
  Future<void> _switchVersionAndQuality({
    int? newMediaIndex,
    TranscodeQualityPreset? newPreset,
    int? newAudioStreamId,
    PlaybackSourceSubtitleChoice? newSubtitleChoice,
  }) async {
    final onPlaybackSourceChanged = widget.onPlaybackSourceChanged;
    if (onPlaybackSourceChanged == null) return;
    try {
      await onPlaybackSourceChanged(
        newMediaIndex: newMediaIndex,
        newPreset: newPreset,
        newAudioStreamId: newAudioStreamId,
        newSubtitleChoice: newSubtitleChoice,
      );
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, t.messages.errorLoading(error: localizedErrorReason(e)));
      }
    }
  }
}
