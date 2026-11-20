import 'dart:async';
import '../mpv/mpv.dart';
import '../utils/app_logger.dart';
import 'ted_models.dart';

/// One video engine per active profile/configuration. Decoders and session
/// listeners retire before a successor may borrow the engine.
class TedPlayerEnginePool {
  final Player Function(bool, bool) create;
  final Duration idleLifetime;
  Player? _player;
  String? _key;
  bool _leased = false, _closed = false;
  Timer? _idle;
  Completer<void>? _released;
  Future<void> _tail = Future.value();
  Future<void> _retirement = Future.value();
  TedPlayerEnginePool({Player Function(bool, bool)? create, this.idleLifetime = const Duration(seconds: 30)})
    : create = create ?? ((exo, hardware) => Player(useExoPlayer: exo, hardwareDecoding: hardware));
  Future<Player> acquire(String scope, {required bool exo, required bool hardware}) {
    final result = _tail.then((_) async {
      if (_leased) await _released!.future;
      await _retirement;
      if (_closed) throw const TedFailure('sign_in_required');
      _idle?.cancel();
      final key = '$scope/$exo/$hardware';
      if (_player != null && _key != key) {
        final old = _player!;
        _player = null;
        await old.dispose();
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

  Future<void> _expire(Player player) async {
    if (_leased || !identical(_player, player)) return;
    _player = null;
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
    final player = _player;
    _player = null;
    if (player != null) await player.dispose();
    await _retirement;
    _leased = false;
    if (_released?.isCompleted == false) _released!.complete();
  }
}
