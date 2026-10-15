import 'ted_models.dart';

/// Account watch state, separate from the copy's immutable download boundary.
class TedDownloadWatch {
  final TedMediaIdentity media;
  final bool played, inProgress;
  final int positionMs;
  final int? durationMs;
  final DateTime? observedAt, completedAt;
  const TedDownloadWatch(
    this.media,
    this.played,
    this.inProgress,
    this.positionMs,
    this.durationMs,
    this.observedAt,
    this.completedAt,
  );
  factory TedDownloadWatch.fromJson(Map<String, dynamic> value) {
    try {
      final state = value['state'] as Map<String, dynamic>;
      DateTime? date(String key) {
        if (value[key] == null) return null;
        final result = DateTime.parse(value[key] as String).toUtc();
        if (result.year < 1970 || result.year > 2100) throw const TedFailure('invalid_response');
        return result;
      }

      final result = TedDownloadWatch(
        TedMediaIdentity.fromJson(state['media'] as Map<String, dynamic>),
        state['played'] as bool,
        value['in_progress'] as bool,
        state['position_ms'] as int,
        state['duration_ms'] as int?,
        date('observed_at'),
        date('completed_at'),
      );
      if (!result.media.playable ||
          result.positionMs < 0 ||
          result.positionMs > 604800000 ||
          result.durationMs != null && (result.durationMs! <= 0 || result.durationMs! > 604800000)) {
        throw const TedFailure('invalid_response');
      }
      return result;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
  Map<String, dynamic> toJson() => {
    'state': {'media': media.toJson(), 'played': played, 'position_ms': positionMs, 'duration_ms': durationMs},
    'in_progress': inProgress,
    'observed_at': observedAt?.toIso8601String(),
    'completed_at': completedAt?.toIso8601String(),
  };
  bool watchedAfter(DateTime? downloadedAt) =>
      !inProgress && played && downloadedAt != null && completedAt != null && completedAt!.isAfter(downloadedAt);

  /// Local events are useful while disconnected. Online TED's applied state
  /// wins, including edits and stale-report decisions from another device.
  TedDownloadWatch withLocal(Map<String, dynamic>? event, int fallbackDuration) {
    if (event == null) return this;
    final at = DateTime.parse(event['observed_at'] as String).toUtc();
    if (observedAt != null && at.isBefore(observedAt!)) return this;
    final position = event['position_ms'] as int;
    final suppliedDuration = event['duration_ms'] as int? ?? 0;
    final duration = suppliedDuration > 0 ? suppliedDuration : fallbackDuration;
    final complete =
        event['kind'] == 'complete' ||
        event['kind'] != 'start' && (duration > 0 ? position * 10 >= duration * 9 : event['natural_eof'] == true);
    return TedDownloadWatch(
      media,
      complete || played,
      !complete,
      complete ? 0 : position,
      duration > 0 ? duration : null,
      at,
      complete ? at : completedAt,
    );
  }
}
