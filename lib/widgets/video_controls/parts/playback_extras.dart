part of '../video_controls.dart';

extension _PlexVideoControlsPlaybackExtrasMethods on _PlexVideoControlsState {
  Future<void> _loadPlaybackExtras({bool forceRefresh = false}) async {
    // Live TV metadata uses EPG rating keys, not library items
    if (widget.isLive) return;
    final loadKey = widget.metadata.globalKey;
    final revision = widget.playbackExtrasRevision;
    // Re-entrancy guard is per item: an in-place episode swap may start the
    // new item's load while the old item's is still in flight.
    if (_isLoadingExtras && _extrasLoadKey == loadKey && !forceRefresh) return;
    _isLoadingExtras = true;
    _extrasLoadKey = loadKey;

    if (widget.playbackExtrasLoader case final loader?) {
      try {
        final extras = await loader();
        if (extras != null &&
            mounted &&
            widget.metadata.globalKey == loadKey &&
            widget.playbackExtrasRevision == revision) {
          _applyPlaybackExtras(extras);
        }
      } finally {
        if (_extrasLoadKey == loadKey && widget.playbackExtrasRevision == revision) _isLoadingExtras = false;
      }
      return;
    }

    _isLoadingExtras = false;
  }

  void _applyPlaybackExtras(PlaybackExtras extras) {
    if (!mounted) return;
    _setControlsState(() {
      _chapters = extras.chapters;
      _markers = extras.markers;
      _chaptersLoaded = true;
      _markersLoaded = true;
    });
    _syncCurrentMarkerForCurrentPosition();
  }
}
