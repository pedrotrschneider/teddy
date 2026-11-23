import 'dart:async';
import '../services/settings_service.dart';
import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_next_cache.dart';
import 'ted_media_transport.dart';

/// Owns the speculative bytes independently of the active decoder's cache.
class TedNextDevicePreparation {
  final TedClient client;
  final Future<(int, int)> Function() budget;
  final void Function()? onEvicted;
  TedPlaybackRelay? _relay;
  TedNextByteCache? _cache;
  bool _closed = false;
  TedNextDevicePreparation(this.client, this.budget, {this.onEvicted});
  Future<void> _prepareCache(TedPlaybackSession session, Future<void> aborted) async {
    if (_closed) throw const TedFailure('unavailable');
    final limits = await budget();
    final resume = session
        .startPosition(rewindSeconds: SettingsService.instance.read(SettingsService.rewindOnResume))
        .inMilliseconds;
    if (_cache != null &&
        (!_cache!.matches(session, resume) ||
            _cache!.plan.aheadBytes > limits.$1 ||
            _cache!.plan.backBytes > limits.$2)) {
      _cache!.dispose();
      _cache = null;
    }
    if (_cache == null) {
      final plan = await client.nextCachePlan(
        session,
        aheadBytes: limits.$1,
        backBytes: limits.$2,
        resumeMs: resume,
        abortTrigger: aborted,
      );
      if (_closed) throw const TedFailure('unavailable');
      if (plan.resumeMs != resume || plan.aheadBytes != limits.$1 || plan.backBytes != limits.$2) {
        throw const TedFailure('invalid_response');
      }
      _cache = TedNextByteCache(session.media, plan, onEvicted: onEvicted);
    }
  }

  Future<void> preCache(TedPlaybackSession session, Future<void> aborted) async {
    await _prepareCache(session, aborted);
    if (_cache!.suspended) throw const TedFailure('next_cache_evicted');
    final relay = TedPlaybackRelay(client.auth, session, cache: _cache);
    _relay = relay;
    unawaited(aborted.then<void>((_) => relay.close()));
    try {
      await relay.preCache();
    } on TedFailure catch (failure) {
      if (failure.code == 'source_selection_required') {
        _cache!.dispose();
        _cache = null;
      }
      rethrow;
    } finally {
      await relay.close();
      if (identical(_relay, relay)) _relay = null;
    }
  }

  TedNextByteCache? take(TedPlaybackSession session) {
    final cache = _cache;
    _cache = null;
    final resume = session
        .startPosition(rewindSeconds: SettingsService.instance.read(SettingsService.rewindOnResume))
        .inMilliseconds;
    if (cache == null) return null;
    if (!cache.matches(session, resume)) {
      cache.dispose();
      return null;
    }
    return cache;
  }

  void discard() {
    if (_closed) return;
    _closed = true;
    unawaited(_relay?.close());
    _cache?.dispose();
    _cache = null;
  }
}
