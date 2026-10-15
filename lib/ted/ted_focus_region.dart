import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/dpad_navigator.dart';
import '../focus/key_event_utils.dart';
import '../focus/input_mode_tracker.dart';

/// A TED browse lane: arrows stay inside its controls until an explicit edge
/// hands focus to the adjacent lane. Tab still follows widget order.
class TedFocusRegion extends StatefulWidget {
  final Widget child;
  final VoidCallback? onUp, onDown, onLeft, onRight, onBack;
  final bool grid, scroll, autofocus;

  /// A field owns caret keys through Plezy's FocusableTextField. The region
  /// must let its unhandled editing keys reach Flutter's text shortcuts.
  final FocusNode? textInputNode;
  const TedFocusRegion({
    super.key,
    required this.child,
    this.onUp,
    this.onDown,
    this.onLeft,
    this.onRight,
    this.onBack,
    this.grid = false,
    this.scroll = true,
    this.autofocus = false,
    this.textInputNode,
  });

  @override
  State<TedFocusRegion> createState() => TedFocusRegionState();
}

class TedFocusRegionState extends State<TedFocusRegion> {
  final _focus = FocusNode(skipTraversal: true, debugLabel: 'ted_focus_region');
  FocusNode? _remembered;
  final _listeners = <FocusNode, VoidCallback>{};
  bool get hasFocus => _focus.hasFocus;

  List<FocusNode> get _controls {
    // Explicit control order keeps a text field before its suffix action,
    // while allowing controls such as Search's Type selector ahead of it.
    final nodes = OrderedTraversalPolicy(
      secondary: WidgetOrderTraversalPolicy(),
    ).sortDescendants(_focus.traversalDescendants, FocusManager.instance.primaryFocus ?? _focus).toList();
    return nodes;
  }

  bool requestFocus({bool first = false}) {
    final controls = _controls;
    if (controls.isEmpty) return false;
    _request(!first && controls.contains(_remembered) ? _remembered! : controls.first);
    return true;
  }

  bool requestNext(FocusNode current) {
    final controls = _controls;
    final index = controls.indexOf(current);
    if (index < 0 || index + 1 >= controls.length) return false;
    _request(controls[index + 1]);
    return true;
  }

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent != false) requestFocus(first: true);
      });
    }
  }

  void _request(FocusNode node) {
    _remembered = node;
    node.requestFocus();
    _reveal(node);
  }

  void _syncControls() {
    if (!mounted) return;
    final controls = _controls;
    for (final node in _listeners.keys.toList()) {
      if (!controls.contains(node)) node.removeListener(_listeners.remove(node)!);
    }
    for (final node in controls) {
      if (_listeners.containsKey(node)) continue;
      void changed() {
        if (node.hasPrimaryFocus) {
          _remembered = node;
          _reveal(node);
        }
      }

      _listeners[node] = changed;
      node.addListener(changed);
      if (node.hasPrimaryFocus) _remembered = node;
    }
  }

  void _reveal(FocusNode node) {
    if (!widget.scroll || InputModeTracker.currentMode != InputMode.keyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || InputModeTracker.currentMode != InputMode.keyboard || !node.hasFocus || node.context == null) {
        return;
      }
      final scrollable = Scrollable.maybeOf(node.context!);
      final viewport = scrollable?.context.findRenderObject();
      if (viewport is RenderBox && viewport.hasSize) {
        final top = viewport.localToGlobal(Offset.zero).dy;
        // Already-visible controls stay still. Leave room for the floating
        // header when returning upwards from an offscreen row.
        if (node.rect.top >= top + 88 && node.rect.bottom <= top + viewport.size.height - 16) return;
      }
      Scrollable.ensureVisible(
        node.context!,
        alignment: .25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    // A modal owns input even before its first control has taken focus.
    if (ModalRoute.of(context)?.isCurrent == false) return KeyEventResult.ignored;
    final current = FocusManager.instance.primaryFocus;
    if (current != null) _remembered = current;
    if (widget.onBack != null) {
      final result = handleBackKeyAction(event, widget.onBack!);
      if (result != KeyEventResult.ignored) return result;
    }
    if (!event.isActionable || !event.logicalKey.isDpadDirection) return KeyEventResult.ignored;
    if (current == widget.textInputNode) return KeyEventResult.ignored;
    final controls = _controls;
    if (current == null || !controls.contains(current)) return KeyEventResult.ignored;
    final key = event.logicalKey;
    FocusNode? target;
    if (widget.grid) {
      // Use actual Wrap geometry, so narrow windows and partial final rows
      // preserve the column without jumping into another browse region.
      final rect = current.rect;
      final candidates = controls.where((candidate) {
        if (candidate == current) return false;
        final other = candidate.rect;
        if (key.isLeftKey || key.isRightKey) {
          if (other.bottom <= rect.top || other.top >= rect.bottom) return false;
          return key.isLeftKey ? other.center.dx < rect.center.dx - 1 : other.center.dx > rect.center.dx + 1;
        }
        return key.isUpKey ? other.bottom <= rect.top + 1 : other.top >= rect.bottom - 1;
      }).toList();
      candidates.sort((a, b) {
        final horizontal = key.isLeftKey || key.isRightKey;
        final majorA = horizontal
            ? (a.rect.center.dx - rect.center.dx).abs()
            : (a.rect.center.dy - rect.center.dy).abs();
        final majorB = horizontal
            ? (b.rect.center.dx - rect.center.dx).abs()
            : (b.rect.center.dy - rect.center.dy).abs();
        final major = majorA.compareTo(majorB);
        if (major != 0) return major;
        return (a.rect.center.dx - rect.center.dx).abs().compareTo((b.rect.center.dx - rect.center.dx).abs());
      });
      target = candidates.firstOrNull;
    } else if (key.isLeftKey || key.isRightKey) {
      final index = controls.indexOf(current) + (key.isLeftKey ? -1 : 1);
      if (index >= 0 && index < controls.length) target = controls[index];
    }
    if (target != null) {
      _request(target);
    } else {
      final edge = key.isUpKey
          ? widget.onUp
          : key.isDownKey
          ? widget.onDown
          : key.isLeftKey
          ? widget.onLeft
          : widget.onRight;
      // Repeats may reach the first control, but must not escape to the rail.
      if (!key.isLeftKey || event is KeyDownEvent) edge?.call();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncControls());
    return FocusTraversalGroup(
      policy: widget.textInputNode == null ? WidgetOrderTraversalPolicy() : OrderedTraversalPolicy(),
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        },
        child: Focus(
          focusNode: _focus,
          canRequestFocus: false,
          onKeyEvent: _key,
          onFocusChange: (focused) {
            if (focused) {
              final node = FocusManager.instance.primaryFocus;
              if (node != null) _reveal(node);
            }
          },
          child: widget.child,
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final entry in _listeners.entries) {
      entry.key.removeListener(entry.value);
    }
    _focus.dispose();
    super.dispose();
  }
}
