import 'dart:async';
import 'package:flutter/material.dart';
import '../focus/key_event_utils.dart';
import '../utils/app_logger.dart';
import 'ted_client.dart';
import 'ted_episode_navigation.dart';
import 'ted_player_route.dart';

/// Owns a player route across prepared episode handoffs. Each episode still
/// has a separate widget/controller lifetime and can close to its own details.
class TedPlayerPageController extends ChangeNotifier {
  final NavigatorState navigator;
  TedPlayerRoute? _route;
  TedPlayerPageEpisode? _episode;
  bool _disposed = false;
  bool _cancelled = false;
  bool get cancelled => _cancelled;

  TedPlayerPageController(this.navigator);

  Future<TedPlayerExit?> show({
    required bool Function(TedTitle target) isPrepared,
    required Widget Function(BuildContext context, TedPlayerPageEpisode episode) builder,
  }) {
    if (_disposed || _cancelled) return Future.value(null);
    if (_episode != null && !_episode!._result.isCompleted) {
      throw StateError('The current player episode has not exited');
    }
    final episode = TedPlayerPageEpisode._(this, builder, isPrepared);
    _episode = episode;
    if (_route == null) {
      late final TedPlayerRoute route;
      route = TedPlayerRoute(
        isPrepared: (target) => _episode?._isPrepared(target) ?? false,
        builder: (_) => _TedPlayerPage(controller: this, route: route),
      );
      _route = route;
      unawaited(navigator.push(route).then((result) => _routeClosed(route, result)));
    } else {
      notifyListeners();
    }
    appLogger.i('TED player page: phase=episode_presented');
    return episode._result.future;
  }

  bool _active(TedPlayerPageEpisode episode) =>
      !_disposed && _route != null && identical(_episode, episode) && !episode._result.isCompleted;

  void _exit(TedPlayerPageEpisode episode, TedPlayerExit result) {
    if (!_active(episode)) return;
    final target = result.target;
    if (target != null &&
        (result.action == TedPlayerAction.next || result.action == TedPlayerAction.completed) &&
        episode._isPrepared(target)) {
      // Remove the outgoing controller before the next one can lease MPV.
      // The route itself stays opaque, so browse details cannot paint here.
      _episode = null;
      notifyListeners();
      episode._result.complete(result);
      appLogger.i('TED player page: phase=prepared_handoff');
    } else {
      final route = _route!;
      if (route.isCurrent) {
        navigator.pop(result);
      } else {
        navigator.removeRoute(route, result);
      }
    }
  }

  void _fail(TedPlayerPageEpisode episode) {
    if (!_active(episode)) return;
    appLogger.w('TED player page: phase=failed_return_to_details');
    _cancelled = true;
    close();
  }

  void _routeClosed(TedPlayerRoute route, TedPlayerExit? result) {
    if (_disposed || !identical(_route, route)) return;
    _route = null;
    if (result == null || result.action == TedPlayerAction.back) _cancelled = true;
    final episode = _episode;
    _episode = null;
    if (episode != null && !episode._result.isCompleted) episode._result.complete(result);
    // Do not rebuild a page that is still running its ordinary Back animation.
  }

  void _routeDisposed(TedPlayerRoute route) => _routeClosed(route, null);

  /// Failure/cancellation removes this specific route, never a newer dialog.
  /// The covered browse tree has already navigated to the current target.
  void close() {
    final route = _route;
    if (route == null) return;
    _routeClosed(route, null);
    if (route.navigator != null) navigator.removeRoute(route);
  }

  @override
  void dispose() {
    if (_disposed) return;
    close();
    _disposed = true;
    super.dispose();
  }
}

/// Source-scoped UI callbacks: a late failure/exit from an outgoing episode
/// cannot close or replace its successor.
class TedPlayerPageEpisode {
  final TedPlayerPageController _owner;
  final Widget Function(BuildContext, TedPlayerPageEpisode) _builder;
  final bool Function(TedTitle) _isPrepared;
  final _result = Completer<TedPlayerExit?>();
  TedPlayerPageEpisode._(this._owner, this._builder, this._isPrepared);

  void exit(TedPlayerExit result) => _owner._exit(this, result);
  void fail() => _owner._fail(this);
}

class _TedPlayerPage extends StatefulWidget {
  final TedPlayerPageController controller;
  final TedPlayerRoute route;
  const _TedPlayerPage({required this.controller, required this.route});
  @override
  State<_TedPlayerPage> createState() => _TedPlayerPageState();
}

class _TedPlayerPageState extends State<_TedPlayerPage> {
  TedPlayerPageEpisode? _episode;
  @override
  void initState() {
    super.initState();
    _episode = widget.controller._episode;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (identical(widget.controller._route, widget.route)) {
      setState(() => _episode = widget.controller._episode);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller._routeDisposed(widget.route);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final episode = _episode;
    if (episode != null) {
      return KeyedSubtree(key: ObjectKey(episode), child: episode._builder(context, episode));
    }
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) => handleBackKeyAction(event, () => Navigator.of(context).pop()),
      child: const ColoredBox(color: Colors.black, child: SizedBox.expand()),
    );
  }
}
