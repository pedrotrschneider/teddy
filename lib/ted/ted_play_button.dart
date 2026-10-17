import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'ted_client.dart';

/// The same resume/progress pill on Home and movie details.
class TedPlayButton extends StatefulWidget {
  final TedTitle title;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool compact;
  const TedPlayButton({super.key, required this.title, required this.onPressed, this.compact = false, this.focusNode});

  @override
  State<TedPlayButton> createState() => _TedPlayButtonState();
}

class _TedPlayButtonState extends State<TedPlayButton> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
  bool _hovered = false, _focused = false;
  bool get _highlighted => widget.onPressed != null && (_hovered || _focused);

  void _syncPulse() {
    final animate = _highlighted && !MediaQuery.disableAnimationsOf(context) && TickerMode.valuesOf(context).enabled;
    if (animate) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant TedPlayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final theme = Theme.of(context), light = theme.brightness == Brightness.light;
    final foreground = light ? theme.scaffoldBackgroundColor : Colors.black;
    final progress = title.durationMs == null ? null : (title.positionMs / title.durationMs!).clamp(0.0, 1.0);
    final remaining = progress == null ? null : math.max(1, ((title.durationMs! - title.positionMs) / 60000).ceil());
    final label = !title.media.playable
        ? 'View show'
        : title.positionMs > 0
        ? (remaining == null ? 'Resume' : '$remaining min left')
        : 'Play';
    final button = FilledButton(
      focusNode: widget.focusNode,
      onPressed: widget.onPressed,
      onHover: (value) {
        setState(() => _hovered = value);
        _syncPulse();
      },
      onFocusChange: (value) {
        setState(() => _focused = value);
        _syncPulse();
      },
      style: FilledButton.styleFrom(
        backgroundColor: light ? theme.colorScheme.onSurface : Colors.white,
        foregroundColor: foreground,
        minimumSize: Size(160, widget.compact ? 44 : 52),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(title.media.playable ? Icons.play_arrow : Icons.info_outline),
          if (title.positionMs > 0 && progress != null) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 42,
              child: LinearProgressIndicator(
                value: progress,
                color: foreground,
                backgroundColor: light ? Colors.white38 : Colors.black26,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
    return AnimatedBuilder(
      animation: _pulse,
      child: button,
      builder: (context, child) => Transform.scale(
        // Transform only the paint/hit area, preserving the shared pill layout.
        // Reduced motion retains a steady selection cue instead of pulsing.
        scale: _highlighted
            ? MediaQuery.disableAnimationsOf(context)
                  ? 1.035
                  : 1.02 + Curves.easeInOut.transform(_pulse.value) * .03
            : 1,
        child: child,
      ),
    );
  }
}
