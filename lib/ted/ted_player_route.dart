import 'package:flutter/material.dart';
import '../utils/app_logger.dart';
import 'ted_episode_navigation.dart';
import 'ted_client.dart';

/// A verified successor keeps the engine and needs no outgoing page animation.
/// Ordinary exits retain the platform transition and native retirement order.
class TedPlayerRoute extends MaterialPageRoute<TedPlayerExit> {
  final bool Function(TedTitle target) isPrepared;
  bool _preparedExit = false;
  Stopwatch? _exit;

  TedPlayerRoute({required super.builder, required this.isPrepared});

  @override
  Duration get reverseTransitionDuration => _preparedExit ? Duration.zero : super.reverseTransitionDuration;

  @override
  bool didPop(TedPlayerExit? result) {
    final target = result?.target;
    _preparedExit =
        target != null &&
        (result!.action == TedPlayerAction.next || result.action == TedPlayerAction.completed) &&
        isPrepared(target);
    final popped = super.didPop(result);
    if (!popped) {
      _preparedExit = false;
      controller?.reverseDuration = reverseTransitionDuration;
      return false;
    }
    _exit = Stopwatch()..start();
    appLogger.i(
      'TED player route: phase=exit prepared_next=$_preparedExit transition_ms=${reverseTransitionDuration.inMilliseconds}',
    );
    return true;
  }

  @override
  void dispose() {
    if (_exit != null) {
      appLogger.i(
        'TED player route: phase=disposed prepared_next=$_preparedExit elapsed_ms=${_exit!.elapsedMilliseconds}',
      );
    }
    super.dispose();
  }
}
