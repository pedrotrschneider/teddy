import 'media_source_info.dart';
import '../models/livetv_capture_buffer.dart';
import '../models/livetv_channel.dart';
import '../models/livetv_dvr.dart';
import '../models/livetv_program.dart';
import '../models/media_grab_operation.dart';
import '../models/media_subscription.dart';
import '../models/transcode_quality_preset.dart';

class LiveProgramInfo {
  /// Program identifier for timeline reporting (Plex program ratingKey).
  final String? id;
  final int? durationMs;

  /// Program start, epoch seconds.
  final int? beginsAt;

  const LiveProgramInfo({this.id, this.durationMs, this.beginsAt});

  static const none = LiveProgramInfo();
}

/// What a live heartbeat learned from the server. Both windows are
/// `TranscodeSession` snapshots (epoch origin plus min/max offsets), but they
/// describe different things:
///
/// - [captureBuffer]: the tuner's seekable history — the coordinate system
///   for time-shift offsets and the timeline's range.
/// - [playbackStream]: the transcode currently feeding the player. Its
///   `startedAt` is the epoch of stream position zero, i.e. the exact clock
///   anchor for `epoch = startedAt + player position`. Plex's own client
///   derives the playhead from this object, not from wall clock (#2100).
///
/// Either may be null when the backend does not report it.
class LiveTimelineUpdate {
  final CaptureBuffer? captureBuffer;
  final CaptureBuffer? playbackStream;

  const LiveTimelineUpdate({this.captureBuffer, this.playbackStream});

  bool get isEmpty => captureBuffer == null && playbackStream == null;
}

abstract class LiveTvPlaybackSession {
  LiveProgramInfo get program;

  /// Whether a TV app may retain this server session while backgrounded.
  LiveTvBackgroundPolicy get backgroundPolicy;

  /// Seekable-history snapshot from session start. Heartbeats may return
  /// fresher ones ([reportTimeline]); the caller owns tracking the current
  /// value.
  CaptureBuffer? get captureBuffer;

  List<MediaSubtitleTrack> get subtitleTracks;

  /// Whether [streamUrlAt] supports a non-null offset.
  bool get canTimeShift;

  /// Build the playable stream URL. [offsetSeconds] positions the stream
  /// that many seconds from the capture-buffer origin — watch-from-start and
  /// time-shift seek are the same operation; `null` plays the live edge.
  /// [subtitleTrack] must be one of [subtitleTracks]; the backend delivers it
  /// in the rebuilt stream (Plex selects it server-side and burns it).
  /// Returns `null` on failure, when an offset is requested but unsupported,
  /// or when the subtitle selection cannot be confirmed — burning against an
  /// unconfirmed selection would weld a wrong stream into the picture.
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack});

  /// Send a playback heartbeat (`'playing'` / `'paused'` / `'stopped'`).
  /// [positionMs] is elapsed playback time; [durationMs] the program
  /// duration when known. Returns what the backend reported back (capture
  /// window, playback-stream origin), null when it reports nothing.
  Future<LiveTimelineUpdate?> reportTimeline({required String state, required int positionMs, required int durationMs});

  /// Release a session that was never adopted: nothing played it and no
  /// heartbeat was ever sent for it (a superseded zap, an unmount mid-start, a
  /// failed recovery). Best-effort; never throws. An adopted session ends with
  /// a `'stopped'` [reportTimeline] instead.
  Future<void> discard();

  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio});
}

enum LiveTvBackgroundPolicy {
  /// Keep the tuned session alive so its capture buffer can be resumed.
  retainSession,

  /// Stop the session when a TV app is backgrounded and leave playback when
  /// the app resumes.
  stopAndExit,
}

enum FavoriteChannelPersistenceMode {
  /// A single write replaces the full backend account's favorite list.
  sharedFullList,

  /// Writes must only include the favorites owned by this server/source.
  serverSlice,
}

class LiveTvStreamResolution {
  final String url;
  final String? playSessionId;
  final String? mediaSourceId;
  final String? liveStreamId;
  final String? playMethod;

  const LiveTvStreamResolution({
    required this.url,
    this.playSessionId,
    this.mediaSourceId,
    this.liveStreamId,
    this.playMethod,
  });
}

abstract class LiveTvSupport {
  /// Recording and DVR administration, when implemented by this backend.
  /// Plex serves it from `/media/subscriptions`; the MediaBrowser family
  /// adapts `/LiveTv/Timers` + `/LiveTv/SeriesTimers`.
  LiveTvDvrSupport? get dvr;

  Future<bool> isAvailable();

  Future<List<LiveTvChannel>> fetchChannels({String? lineup});

  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to});

  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  });

  Future<String> buildFavoriteChannelSource({String? lineup});

  String get favoriteStoreKey;

  FavoriteChannelPersistenceMode get favoritePersistenceMode;

  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent});

  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent});
}

/// Recording and DVR administration capability.
///
/// Kept separate from [LiveTvSupport] so backends that support channels,
/// guide data, and playback do not need placeholder methods for unsupported
/// recording APIs. The payload models are Plex wire shapes; the MediaBrowser
/// implementation synthesizes them from `/LiveTv/Timers` /
/// `/LiveTv/SeriesTimers` DTOs.
abstract class LiveTvDvrSupport {
  Future<List<LiveTvDvr>> fetchDvrs();
  Future<void> reloadGuide(String dvrId);

  Future<List<SubscriptionTemplate>> getSubscriptionTemplate(String guid);
  Future<List<MediaSubscription>> fetchRecordingRules({bool includeGrabs = true, bool includeStorage = true});
  Future<MediaSubscription?> createRecordingRule(MediaSubscriptionCreateRequest request);
  Future<MediaSubscription?> updateRecordingRule(
    String subscriptionId,
    Map<String, Object?> prefs, {
    void Function()? checkCurrent,
  });
  Future<void> deleteRecordingRule(String subscriptionId);

  /// Whether [processRecordingRules] triggers real server-side work. Plex's
  /// "re-evaluate rules now" (`POST /media/subscriptions/process`) has no
  /// MediaBrowser equivalent, so UI hides the affordance when no DVR-capable
  /// server reports support.
  bool get supportsRuleProcessing;
  Future<void> processRecordingRules();
  Future<List<MediaGrabOperation>> fetchScheduledRecordings();
  Future<void> cancelGrab(String operationId);
  Future<List<MediaSubscription>> fetchSubscriptionMapping({
    required String providerId,
    required List<String> ratingKeys,
    bool includeStorage = true,
  });
}
