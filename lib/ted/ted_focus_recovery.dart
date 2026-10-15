import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../utils/platform_detector.dart';
import '../widgets/overlay_sheet.dart';
import '../focus/input_mode_tracker.dart';

/// Restore the active route's last control, or its first eligible control.
/// Modal routes participate too, so an underlying page never takes their input.
class TedFocusRoutes extends NavigatorObserver {
  final routes = <Route<dynamic>>[];
  VoidCallback? changed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
    changed?.call();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    changed?.call();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    changed?.call();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = routes.indexOf(oldRoute!);
    if (index >= 0) {
      if (newRoute == null) {
        routes.removeAt(index);
      } else {
        routes[index] = newRoute;
      }
    }
    changed?.call();
  }
}

class TedFocusRecovery extends StatefulWidget {
  final TedFocusRoutes routes;
  final Widget child;
  const TedFocusRecovery({super.key, required this.routes, required this.child});
  @override
  State<TedFocusRecovery> createState() => _TedFocusRecoveryState();
}

class _TedFocusRecoveryState extends State<TedFocusRecovery> with WidgetsBindingObserver, WindowListener {
  final _remembered = <Route<dynamic>, FocusNode>{};
  final _defaults = <Route<dynamic>, VoidCallback>{};
  bool _scheduled = false;
  @override
  void initState() {
    super.initState();
    widget.routes.changed = _schedule;
    FocusManager.instance.addListener(_focusChanged);
    WidgetsBinding.instance.addObserver(this);
    if (PlatformDetector.isDesktopOS()) windowManager.addListener(this);
  }

  void _focusChanged() {
    final current = widget.routes.routes.lastOrNull;
    final node = FocusManager.instance.primaryFocus;
    if (current != null && _eligible(node, current)) _remembered[current] = node!;
    _schedule();
  }

  bool _eligible(FocusNode? node, Route<dynamic> route) =>
      node != null &&
      node is! FocusScopeNode &&
      node.canRequestFocus &&
      node.context != null &&
      ModalRoute.of(node.context!) == route;
  void _schedule() {
    if (_scheduled || !mounted || !PlatformDetector.isTV()) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !PlatformDetector.isTV() || InputModeTracker.currentMode != InputMode.keyboard) return;
      final route = widget.routes.routes.lastOrNull;
      if (route == null || !route.isCurrent) return;
      final primary = FocusManager.instance.primaryFocus;
      // Embedded sheets share their route with the player. A sheet scope is a
      // valid temporary focus owner, and restoration must stay inside it.
      final context = _eligible(primary, route) ? primary!.context : _remembered[route]?.context;
      final sheet = context == null ? null : OverlaySheetController.maybeOf(context);
      if (sheet?.isOpen ?? false) {
        if (!sheet!.ownsFocus(primary)) sheet.refocus();
        return;
      }
      if (_eligible(primary, route)) return;
      _remembered.removeWhere((route, _) => !widget.routes.routes.contains(route));
      final remembered = _remembered[route];
      if (_eligible(remembered, route)) {
        remembered!.requestFocus();
        return;
      }
      final fallback = _defaults[route];
      if (fallback != null) {
        fallback();
        return;
      }
      final controls = FocusManager.instance.rootScope.traversalDescendants.where(
        (node) => !node.skipTraversal && _eligible(node, route),
      );
      controls.firstOrNull?.requestFocus();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void onWindowFocus() => _schedule();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _schedule();
  }

  @override
  void dispose() {
    widget.routes.changed = null;
    FocusManager.instance.removeListener(_focusChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (PlatformDetector.isDesktopOS()) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return widget.child;
  }
}

class TedDefaultFocus extends StatefulWidget {
  final VoidCallback restore;
  final Widget child;
  const TedDefaultFocus({super.key, required this.restore, required this.child});
  @override
  State<TedDefaultFocus> createState() => _TedDefaultFocusState();
}

class _TedDefaultFocusState extends State<TedDefaultFocus> {
  _TedFocusRecoveryState? _recovery;
  Route<dynamic>? _route;
  void _restore() => widget.restore();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _recovery = context.findAncestorStateOfType<_TedFocusRecoveryState>();
    _route = ModalRoute.of(context);
    if (_route != null) _recovery?._defaults[_route!] = _restore;
  }

  @override
  void dispose() {
    if (_recovery?._defaults[_route] == _restore) _recovery?._defaults.remove(_route);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
