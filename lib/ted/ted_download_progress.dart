import 'ted_models.dart';

/// Effective file throughput, including time between ranges. Native callbacks
/// report bursts within each range; completion callbacks are synthetic.
class TedDownloadRate {
  static const window = Duration(seconds: 5);
  final _samples = <({Duration at, int bytes})>[];
  Duration? _lastAdvance;

  TedDownloadRate(int received, Duration now) {
    _samples.add((at: now, bytes: received));
  }

  void record(int received, Duration now) {
    final last = _samples.last;
    if (received <= last.bytes || now < last.at) return;
    if (now == last.at) {
      _samples[_samples.length - 1] = (at: now, bytes: received);
    } else {
      _samples.add((at: now, bytes: received));
    }
    _lastAdvance = now;
    _trim(now - window);
  }

  void _trim(Duration cutoff) {
    // Retain one point before the window for interpolation at its boundary.
    while (_samples.length > 1 && _samples[1].at <= cutoff) {
      _samples.removeAt(0);
    }
  }

  double? bytesPerSecond(Duration now) {
    if (_lastAdvance == null || now < _samples.last.at || now - _lastAdvance! >= window) return null;
    final cutoff = now - window;
    _trim(cutoff);
    var start = _samples.first.at;
    var baseline = _samples.first.bytes.toDouble();
    if (start < cutoff && _samples.length > 1) {
      final next = _samples[1];
      baseline += (next.bytes - baseline) * (cutoff - start).inMicroseconds / (next.at - start).inMicroseconds;
      start = cutoff;
    }
    final elapsed = (now - start).inMicroseconds;
    if (elapsed < 1000000) return null; // warm up rather than extrapolate a tiny first sample
    return (_samples.last.bytes - baseline) * 1000000 / elapsed;
  }
}

class TedTransferProgress {
  final int received;
  final double? bytesPerSecond;
  const TedTransferProgress(this.received, this.bytesPerSecond);
}

/// Device queue projection. Displayed in-flight bytes are never resume data.
class TedDownloadProgress {
  final int total, completed, received, bytes;
  final String status;
  final bool grouped;
  final double? bytesPerSecond;
  const TedDownloadProgress({
    required this.total,
    required this.completed,
    required this.received,
    required this.bytes,
    required this.status,
    required this.grouped,
    this.bytesPerSecond,
  });
  bool get pending => total > completed;
  double? get fraction =>
      grouped ? (total == 0 ? null : completed / total) : (bytes <= 0 ? null : (received / bytes).clamp(0, 1));
  String get label {
    if (grouped) {
      final current = completed + (status == 'downloading' || status == 'preparing' ? 1 : 0);
      final verb = switch (status) {
        'downloading' || 'preparing' => 'Downloading',
        'complete' => 'Downloaded',
        'paused' => 'Paused',
        'failed' => 'Failed',
        _ => 'Queued',
      };
      return '$verb ${current.clamp(0, total)} of $total';
    }
    final verb = switch (status) {
      'downloading' => received == bytes ? 'Finishing' : 'Downloading',
      'complete' => 'Downloaded',
      'paused' => 'Paused',
      'failed' => 'Failed',
      'preparing' => 'Preparing',
      _ => 'Queued',
    };
    return '$verb${fraction == null ? '' : ' · ${(fraction! * 100).floor()}%'}';
  }

  String get speed =>
      bytesPerSecond == null ? 'Measuring speed…' : '${(bytesPerSecond! * 8 / 1000000).toStringAsFixed(1)} Mbps';

  static TedDownloadProgress? select(
    Iterable<Map<String, dynamic>> files,
    Iterable<Map<String, dynamic>> queue,
    Map<String, TedTransferProgress> transfers,
    Set<TedMediaIdentity> preparing,
    TedMediaIdentity media, {
    int? season,
  }) {
    bool matches(TedMediaIdentity candidate) {
      if (media.kind != 'series') return candidate == media;
      if (candidate.kind != 'episode') return false;
      final parts = candidate.id.split(':');
      return parts[0] == media.id && (season == null || int.parse(parts[1]) == season);
    }

    final selected = <TedMediaIdentity, Map<String, dynamic>>{};
    for (final row in [...queue, ...files]) {
      final identity = TedMediaIdentity.fromJson(Map<String, dynamic>.from(row['media'] as Map));
      if (matches(identity)) selected[identity] = row; // prepared file wins over its queue intent
    }
    if (selected.isEmpty) return null;
    var completed = 0, received = 0, bytes = 0;
    var active = false, preparation = false, paused = false, failed = false;
    double? speed;
    for (final entry in selected.entries) {
      final row = entry.value, status = row['status'];
      final live = status == 'downloading' ? transfers[row['id']] : null;
      bytes += row['bytes'] as int? ?? 0;
      received += live?.received ?? (row['received'] as int? ?? 0);
      if (status == 'complete') completed++;
      active |= status == 'downloading';
      preparation |= preparing.contains(entry.key);
      paused |= status == 'paused';
      failed |= status == 'failed';
      if (live?.bytesPerSecond != null) speed = (speed ?? 0) + live!.bytesPerSecond!;
    }
    return TedDownloadProgress(
      total: selected.length,
      completed: completed,
      received: received,
      bytes: bytes,
      grouped: media.kind == 'series',
      bytesPerSecond: speed,
      status: active
          ? 'downloading'
          : preparation
          ? 'preparing'
          : completed == selected.length
          ? 'complete'
          : failed
          ? 'failed'
          : paused
          ? 'paused'
          : 'queued',
    );
  }
}
