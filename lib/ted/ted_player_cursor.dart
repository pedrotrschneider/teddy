import 'dart:async';
import 'package:flutter/material.dart';

/// The pointer hides over this player after inactivity, even when paused or
/// windowed. The translucent annotation does not consume clicks or scrubs.
class TedPlayerCursor extends StatefulWidget {
  final Widget child;
  const TedPlayerCursor({super.key, required this.child});
  @override
  State<TedPlayerCursor> createState() => _TedPlayerCursorState();
}

class _TedPlayerCursorState extends State<TedPlayerCursor> {
  Timer? _idle;
  bool _hidden = false;
  void _activity() {
    _idle?.cancel();
    if (_hidden) setState(() => _hidden = false);
    _idle = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hidden = true);
    });
  }

  @override
  void dispose() {
    _idle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => _activity(),
    onHover: (_) => _activity(),
    onExit: (_) {
      _idle?.cancel();
      if (_hidden) setState(() => _hidden = false);
    },
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_hidden)
          const Positioned.fill(
            child: MouseRegion(
              cursor: SystemMouseCursors.none,
              opaque: false,
              hitTestBehavior: HitTestBehavior.translucent,
              child: SizedBox.expand(),
            ),
          ),
      ],
    ),
  );
}
