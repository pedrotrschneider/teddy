import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'ted_models.dart';

class TedCachePlan {
  final int size, resumeMs, durationMs, start, end, aheadBytes, backBytes;
  final String etag;
  const TedCachePlan({
    required this.size,
    required this.etag,
    required this.resumeMs,
    required this.durationMs,
    required this.start,
    required this.end,
    required this.aheadBytes,
    required this.backBytes,
  });
  factory TedCachePlan.fromJson(Map<String, dynamic> value) {
    try {
      final plan = TedCachePlan(
        size: value['size'] as int,
        etag: value['etag'] as String,
        resumeMs: value['resume_ms'] as int,
        durationMs: value['duration_ms'] as int,
        start: value['start'] as int,
        end: value['end'] as int,
        aheadBytes: value['ahead_bytes'] as int,
        backBytes: value['back_bytes'] as int,
      );
      if (plan.size <= 0 ||
          plan.size > 32 << 40 ||
          plan.start < 0 ||
          plan.end < plan.start ||
          plan.end >= plan.size ||
          plan.resumeMs < 0 ||
          plan.durationMs <= plan.resumeMs ||
          plan.durationMs > 604800000 ||
          plan.aheadBytes < 1 ||
          plan.aheadBytes > 256 << 20 ||
          plan.backBytes < 0 ||
          plan.backBytes > 128 << 20 ||
          !plan.etag.startsWith('"') ||
          !plan.etag.endsWith('"') ||
          plan.etag.length > 1024) {
        throw const TedFailure('invalid_response');
      }
      return plan;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }

  /// Container bytes count toward the same forward allocation. Playable
  /// forward bytes precede the backward window; overlaps are retained once.
  List<(int, int)> get ranges {
    final head = min(size, min(2 << 20, max(1, aheadBytes ~/ 4)));
    final tail = min(size - head, min(128 << 10, aheadBytes ~/ 16));
    final overhead = min(head, start) + tail;
    final forwardEnd = min(end, start + max(1, aheadBytes - overhead) - 1).toInt();
    return [
      (0, head - 1),
      if (tail > 0) (size - tail, size - 1),
      (start, forwardEnd),
      if (resumeMs > 0 && start > 0 && backBytes > 0) (max(0, start - backBytes), start - 1),
    ];
  }
}

/// Disposable encoded bytes for one file/resume, never viewing state or a disk
/// download. The foreground relay adopts these only after fresh authorization
/// and representation validation. Memory pressure drops speculation first.
class TedNextByteCache with WidgetsBindingObserver {
  final TedMediaIdentity media;
  final TedCachePlan plan;
  final void Function()? onEvicted;
  final _pieces = <(int, Uint8List)>[];
  int bytes = 0;
  bool ready = false, disposed = false;
  final _sinceTrim = Stopwatch();
  TedNextByteCache(this.media, this.plan, {this.onEvicted}) {
    WidgetsBinding.instance.addObserver(this);
  }
  bool get suspended => _sinceTrim.isRunning && _sinceTrim.elapsed < const Duration(minutes: 1);
  bool matches(TedPlaybackSession session, int intendedResume) =>
      !disposed && media == session.media && intendedResume == plan.resumeMs;
  int _before(int offset) {
    var low = 0, high = _pieces.length - 1;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      if (_pieces[middle].$1 <= offset) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return high;
  }

  Uint8List? read(int offset, int end) {
    if (disposed) return null;
    final index = _before(offset);
    if (index >= 0) {
      final piece = _pieces[index];
      final at = offset - piece.$1;
      if (at >= 0 && at < piece.$2.length) {
        return Uint8List.sublistView(piece.$2, at, min(piece.$2.length, end - piece.$1 + 1));
      }
    }
    return null;
  }

  void put(int start, List<int> data) {
    if (disposed || suspended) throw const TedFailure('next_cache_evicted');
    var offset = start;
    final end = start + data.length - 1;
    while (offset <= end) {
      final held = read(offset, end);
      if (held != null) {
        offset += held.length;
        continue;
      }
      final after = _before(offset) + 1;
      final following = after < _pieces.length ? _pieces[after] : null;
      final through = min(end, following == null ? end : following.$1 - 1);
      final length = through - offset + 1;
      if (length > plan.aheadBytes + plan.backBytes - bytes) throw const TedFailure('invalid_response');
      // Copy only retained gaps so a tiny view cannot pin an oversized network
      // chunk, and duplicate response ranges cannot spend the budget twice.
      final retained = Uint8List.fromList(data.sublist(offset - start, through - start + 1));
      _pieces.insert(after, (offset, retained));
      bytes += length;
      offset = through + 1;
    }
  }

  bool covers(int start, int end) {
    while (start <= end) {
      final data = read(start, end);
      if (data == null) return false;
      start += data.length;
    }
    return true;
  }

  @override
  void didHaveMemoryPressure() {
    if (disposed) return;
    _sinceTrim
      ..reset()
      ..start();
    _pieces.clear();
    bytes = 0;
    ready = false;
    onEvicted?.call();
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    ready = false;
    _pieces.clear();
    bytes = 0;
    WidgetsBinding.instance.removeObserver(this);
  }
}
