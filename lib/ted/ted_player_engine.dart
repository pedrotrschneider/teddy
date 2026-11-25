import 'dart:async';
import '../mpv/mpv.dart';
import '../utils/app_logger.dart';
import 'ted_models.dart';

// Owner-accepted on Mac; keep a build-time escape hatch for comparisons.
// The caller retains the Mac guard until other native outputs are validated.
const tedDirectNextReplacement = bool.fromEnvironment('TEDDY_DIRECT_NEXT_REPLACEMENT', defaultValue: true);

/// One video engine per active profile/configuration. Session listeners retire
/// before a successor borrows it; ordinary release also stops native outputs.
class TedPlayerEnginePool {
  final Player Function(bool, bool) create;
  final Duration idleLifetime;
  final Duration replacementLifetime;
  Player? _player;
  String? _key;
  bool _leased = false, _closed = false;
  Timer? _idle;
  Completer<void>? _released;
  Future<void> _tail = Future.value();
  Future<void> _retirement = Future.value();
  Object? _retirementOwner;
  _PendingReplacement? _replacement;
  TedPlayerEnginePool({
    Player Function(bool, bool)? create,
    this.idleLifetime = const Duration(seconds: 30),
    this.replacementLifetime = const Duration(seconds: 10),
  }) : create = create ?? ((exo, hardware) => Player(useExoPlayer: exo, hardwareDecoding: hardware));
  Future<Player> acquire(String scope, {required bool exo, required bool hardware}) {
    final result = _tail.then((_) async {
      if (_leased) await _released!.future;
      await _retirement;
      if (_closed) throw const TedFailure('sign_in_required');
      _idle?.cancel();
      final key = '$scope/$exo/$hardware';
      if (_player != null && _key != key) {
        await cancelReplacement();
        final old = _player;
        _player = null;
        await old?.dispose();
      }
      final reused = _player != null;
      _player ??= create(exo, hardware);
      _key = key;
      _leased = true;
      _released = Completer<void>();
      appLogger.i('TED player engine: phase=${reused ? 'reused' : 'created'} backend=${_player!.playerType}');
      return _player!;
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<(int, int)> cacheBudget() async {
    final player = _player;
    if (player == null || _closed) throw const TedFailure('next_cache_evicted');
    int parse(String? value, int fallback, int ceiling) => int.tryParse(value ?? '')?.clamp(0, ceiling) ?? fallback;
    final ahead = await player.getProperty('demuxer-max-bytes').timeout(const Duration(seconds: 2));
    final back = await player.getProperty('demuxer-max-back-bytes').timeout(const Duration(seconds: 2));
    return (parse(ahead, 32 << 20, 256 << 20), parse(back, 16 << 20, 128 << 20));
  }

  Future<void> release(Player player, {required bool retain}) async {
    if (!identical(player, _player)) {
      await player.dispose();
      return;
    }
    await cancelReplacement();
    if (!identical(player, _player)) {
      await player.dispose();
      return;
    }
    try {
      if (retain && !_closed && player.playerType == 'mpv') {
        await player.stop().timeout(const Duration(seconds: 10));
        await player.clearVideoFrameRate().timeout(const Duration(seconds: 10));
        _idle = Timer(idleLifetime, () => unawaited(_expire(player)));
        appLogger.i('TED player engine: phase=retained seconds=${idleLifetime.inSeconds}');
      } else {
        _player = null;
        await player.dispose();
      }
    } catch (_) {
      _player = null;
      appLogger.w('TED player engine: phase=retention_failed');
      await player.dispose();
    } finally {
      _leased = false;
      if (_released?.isCompleted == false) _released!.complete();
    }
  }

  int? replacingSourceId(Player player) => identical(player, _player) ? _replacement?.sourceId : null;

  /// The outgoing controller has saved its report, paused and cancelled its
  /// listeners. Lend the same core without stop/hide/output reset. This future
  /// keeps its transport alive until a distinct START_FILE retires that source.
  Future<void> releaseForReplacement(Player player, int sourceId, {Object? owner}) async {
    if (_closed || !identical(player, _player) || player.playerType != 'mpv' || _replacement != null) {
      await release(player, retain: !_closed);
      return;
    }
    _idle?.cancel();
    final pending = _PendingReplacement(player, sourceId, owner);
    _replacement = pending;
    pending.events = player.streams.sourceStarted.listen((event) {
      if (event.sourceId != sourceId) unawaited(_finishReplacement(pending, stop: false));
    });
    pending.timeout = Timer(replacementLifetime, () {
      if (!identical(_replacement, pending)) return;
      appLogger.w('TED player engine: phase=replacement_timeout source=$sourceId');
      unawaited(cancelReplacement());
    });
    _leased = false;
    if (_released?.isCompleted == false) _released!.complete();
    appLogger.i('TED player engine: phase=kept_for_replacement source=$sourceId');
    await pending.done.future;
  }

  /// Failed authorization/preparation, Back, profile change or shutdown must
  /// retire a paused source even when no successor ever starts.
  Future<void> cancelReplacement({Object? owner}) {
    final pending = _replacement;
    if (pending == null) {
      return owner == null || identical(owner, _retirementOwner) ? _retirement : Future<void>.value();
    }
    if (owner != null && !identical(owner, pending.owner)) return Future<void>.value();
    _retirementOwner = pending.owner;
    return _retirement = _finishReplacement(pending, stop: true);
  }

  Future<void> _finishReplacement(_PendingReplacement pending, {required bool stop}) async {
    if (!identical(_replacement, pending)) return;
    _replacement = null;
    pending.timeout?.cancel();
    try {
      await pending.cancelEvents();
      if (stop && identical(_player, pending.player)) {
        await pending.player.stop().timeout(const Duration(seconds: 10));
        await pending.player.clearVideoFrameRate().timeout(const Duration(seconds: 10));
        if (!_closed && !_leased) _idle = Timer(idleLifetime, () => unawaited(_expire(pending.player)));
      }
      appLogger.i(
        'TED player engine: phase=${stop ? 'replacement_cancelled' : 'replacement_started'} source=${pending.sourceId}',
      );
    } catch (_) {
      if (identical(_player, pending.player)) _player = null;
      appLogger.w('TED player engine: phase=replacement_retirement_failed source=${pending.sourceId}');
      try {
        await pending.player.dispose();
      } catch (_) {
        appLogger.w('TED player engine: phase=replacement_disposal_failed');
      }
    } finally {
      if (!pending.done.isCompleted) pending.done.complete();
    }
  }

  Future<void> _expire(Player player) async {
    if (_leased || !identical(_player, player)) return;
    _player = null;
    _retirementOwner = null;
    _retirement = player.dispose().then<void>(
      (_) => appLogger.i('TED player engine: phase=expired'),
      onError: (Object _) => appLogger.w('TED player engine: phase=retirement_failed'),
    );
    await _retirement;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _idle?.cancel();
    await cancelReplacement();
    final player = _player;
    _player = null;
    if (player != null) await player.dispose();
    await _retirement;
    _leased = false;
    if (_released?.isCompleted == false) _released!.complete();
  }
}

class _PendingReplacement {
  final Player player;
  final int sourceId;
  final Object? owner;
  final done = Completer<void>();
  StreamSubscription<PlayerSourceStarted>? events;
  Timer? timeout;
  _PendingReplacement(this.player, this.sourceId, this.owner);
  Future<void> cancelEvents() async => events?.cancel();
}
