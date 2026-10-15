import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/dpad_navigator.dart';
import '../focus/focus_theme.dart';
import '../focus/input_mode_tracker.dart';
import '../services/device_performance.dart';
import '../theme/mono_tokens.dart';
import '../utils/platform_detector.dart';
import 'app_icon.dart';

abstract final class NavigationRailLayout {
  static const double collapsedWidth = 80;
  static const double expandedWidth = 220;
  static Duration get expandDuration => DevicePerformance.reducedDuration(const Duration(milliseconds: 250));
  static const Curve expandCurve = Curves.easeInOutCubicEmphasized;
  static double collapsedWidthForContext(BuildContext _) => collapsedWidth;
  static double horizontalPaddingForContext(BuildContext _, {required bool isCollapsed}) => isCollapsed ? 4 : 12;
}

/// SELECT activates the rail row, RIGHT hands off to the content area.
KeyEventResult _handleRailItemKey(KeyEvent event, {required VoidCallback onSelect, VoidCallback? onNavigateRight}) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  if (event.logicalKey.isSelectKey) {
    InputModeTracker.reportNonPointerInput();
    onSelect();
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.arrowRight && onNavigateRight != null) {
    onNavigateRight();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

/// Reusable navigation rail item widget that handles focus, selection, and interaction.
///
/// Renders the two M3 Expressive destination layouts and morphs between them:
/// collapsed is an icon-only 56x32 pill indicator centered in the strip
/// (announced via [collapsedLabel]); expanded is a full-width stadium row
/// with leading icon and [label]. Items that never render collapsed
/// (library rows) leave [collapsedLabel] null and always use the expanded
/// layout.
class NavigationRailItem extends StatelessWidget {
  /// M3E collapsed-rail active indicator geometry.
  static const double collapsedIndicatorWidth = 56;
  static const double collapsedIndicatorHeight = 32;

  /// Fixed collapsed item height so the collapse morph interpolates between
  /// known extents (32px pill + breathing room).
  static const double collapsedItemHeight = 40;

  final IconData icon;
  final IconData? selectedIcon;

  /// Custom leading widget rendered instead of the [icon] (e.g. the Now
  /// Playing item's equalizer). Should be at most [iconSize] tall/wide.
  final Widget? iconWidget;
  final Widget label;

  /// Base color inherited by single-style text labels. During the morph its
  /// alpha is changed at the leaf, avoiding an opacity layer for the row.
  final Color? labelColor;

  /// Builds labels with more than one text color at [opacity]. Non-text
  /// labels without a builder use one opacity layer only while morphing.
  final Widget Function(double opacity)? labelBuilder;

  /// Semantic label for the icon-only collapsed pill. Null means the item
  /// has no collapsed representation and always lays out expanded.
  final String? collapsedLabel;

  /// Widget rendered after the [label] (e.g. a section header's chevron).
  /// Expanded layout only.
  final Widget? trailing;

  /// Builds a trailing leaf at [opacity] when it should fade with the label.
  final Widget Function(double opacity)? trailingBuilder;
  final bool isSelected;
  final bool isCollapsed;
  final VoidCallback onTap;
  final FocusNode focusNode;
  final bool autofocus;
  final double iconSize;

  /// Horizontal content padding of the expanded row.
  final double horizontalPadding;

  /// Fixed content width of the expanded layout, so the collapse morph and
  /// the rail width animation stay in lockstep.
  final double expandedContentWidth;
  final double? collapsedContentWidth;

  /// Expanded row height: fixed for collapsible items, a minimum for
  /// expanded-only items (whose labels may add a second line).
  final double expandedHeight;
  final bool suppressSelectedBackground;

  /// Called when RIGHT arrow is pressed to navigate to content area.
  final VoidCallback? onNavigateRight;
  final MouseCursor? mouseCursor;

  const NavigationRailItem({
    super.key,
    required this.icon,
    this.selectedIcon,
    this.iconWidget,
    required this.label,
    this.collapsedLabel,
    this.labelColor,
    this.labelBuilder,
    this.trailing,
    this.trailingBuilder,
    required this.isSelected,
    this.isCollapsed = false,
    required this.onTap,
    required this.focusNode,
    this.autofocus = false,
    this.iconSize = 22,
    this.horizontalPadding = 17,
    this.expandedContentWidth = NavigationRailLayout.expandedWidth - 24,
    this.collapsedContentWidth,
    this.expandedHeight = 48,
    this.suppressSelectedBackground = false,
    this.onNavigateRight,
    this.mouseCursor,
  });

  Color? _indicatorColorForLayout(MonoTokens t, {required bool collapsedLayout}) {
    // The collapsed TV rail is a transparent overlay strip; a persistent
    // active pill over artwork is noise there, so it shows focus only.
    final showSelected = isSelected && !suppressSelectedBackground && !(collapsedLayout && PlatformDetector.isTV());
    if (showSelected) return t.text.withValues(alpha: 0.1);
    return null;
  }

  BoxDecoration _indicatorDecoration(MonoTokens t, {required bool focused, required double expansion}) {
    return BoxDecoration(
      color: Color.lerp(
        _indicatorColorForLayout(t, collapsedLayout: true),
        _indicatorColorForLayout(t, collapsedLayout: false),
        expansion,
      ),
      borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
      border: Border.all(
        color: focused ? Colors.white : Colors.transparent,
        width: FocusTheme.focusBorderWidth,
        // Paint inside the pill so rail clipping never cuts off the outline.
        strokeAlign: BorderSide.strokeAlignInside,
      ),
    );
  }

  Widget _leadingIcon(MonoTokens t) =>
      iconWidget ??
      AppIcon(
        isSelected && selectedIcon != null ? selectedIcon! : icon,
        fill: 1,
        size: iconSize,
        color: isSelected ? t.text : t.textMuted,
      );

  double _collapsedItemWidth(BuildContext context) =>
      collapsedContentWidth ??
      (NavigationRailLayout.collapsedWidthForContext(context) -
          2 * NavigationRailLayout.horizontalPaddingForContext(context, isCollapsed: true));

  /// M3E collapsed destination: an icon-only pill indicator.
  Widget _buildCollapsedLayout(BuildContext context, MonoTokens t, {required bool focused}) {
    final width = _collapsedItemWidth(context);
    return SizedBox(
      width: width,
      height: collapsedItemHeight,
      child: Center(
        child: Semantics(
          label: collapsedLabel,
          child: Container(
            width: width < collapsedIndicatorWidth ? width : collapsedIndicatorWidth,
            height: collapsedIndicatorHeight,
            alignment: .center,
            decoration: _indicatorDecoration(t, focused: focused, expansion: 0),
            child: _leadingIcon(t),
          ),
        ),
      ),
    );
  }

  /// M3E expanded destination: full-width stadium indicator behind the row.
  Widget _labelAtOpacity(BuildContext context, double opacity) {
    final builder = labelBuilder;
    if (builder != null) return builder(opacity);

    final textStyle = label is Text ? (label as Text).style : null;
    final inheritsTextColor =
        label is Text &&
        (textStyle == null || (textStyle.inherit && textStyle.color == null && textStyle.foreground == null));
    final color = inheritsTextColor ? labelColor ?? DefaultTextStyle.of(context).style.color : null;
    if (color != null) {
      return DefaultTextStyle.merge(
        style: TextStyle(color: color.withValues(alpha: color.a * opacity)),
        child: label,
      );
    }
    if (opacity >= 1) return label;

    // The reconnect progress indicator is the only production caller of this
    // path. It cannot inherit text color, so retain one small opacity layer
    // rather than a layer for every destination row.
    return Opacity(opacity: opacity, child: label);
  }

  Widget? _trailingAtOpacity(double opacity) {
    final builder = trailingBuilder;
    return builder == null ? trailing : builder(opacity);
  }

  Widget _buildExpandedContent(
    BuildContext context,
    MonoTokens t, {
    required double labelOpacity,
    required bool showLeading,
  }) {
    return Row(
      children: [
        if (showLeading) _leadingIcon(t) else SizedBox(width: iconSize, height: iconSize),
        const SizedBox(width: 11),
        Expanded(child: _labelAtOpacity(context, labelOpacity)),
        ?_trailingAtOpacity(labelOpacity),
      ],
    );
  }

  Widget _buildExpandedLayout(BuildContext context, MonoTokens t, {required bool focused, required bool fixedHeight}) {
    return Container(
      constraints: fixedHeight ? null : BoxConstraints(minHeight: expandedHeight),
      alignment: .centerLeft,
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: fixedHeight ? 0 : 8),
      decoration: _indicatorDecoration(t, focused: focused, expansion: 1),
      child: _buildExpandedContent(context, t, labelOpacity: 1, showLeading: true),
    );
  }

  /// At the endpoints only the active layout exists in the tree. Mid-morph a
  /// single icon moves with the pill geometry while label and indicator color
  /// alpha provide the crossfade without subtree opacity layers.
  Widget _buildMorphingLayouts(BuildContext context, MonoTokens t, {required bool focused, required double expansion}) {
    if (expansion <= 0) return _buildCollapsedLayout(context, t, focused: focused);
    if (expansion >= 1) {
      return SizedBox(
        width: expandedContentWidth,
        height: expandedHeight,
        child: _buildExpandedLayout(context, t, focused: focused, fixedHeight: true),
      );
    }

    final collapsedWidth = _collapsedItemWidth(context);
    const collapsedHeight = collapsedItemHeight;
    final collapsedPillWidth = collapsedWidth < collapsedIndicatorWidth ? collapsedWidth : collapsedIndicatorWidth;
    final indicatorLeft = lerpDouble((collapsedWidth - collapsedPillWidth) / 2, 0, expansion);
    final indicatorTop = lerpDouble((collapsedHeight - collapsedIndicatorHeight) / 2, 0, expansion);
    final iconLeft = lerpDouble((collapsedWidth - iconSize) / 2, horizontalPadding, expansion);
    final iconTop = lerpDouble((collapsedHeight - iconSize) / 2, (expandedHeight - iconSize) / 2, expansion);

    return SizedBox(
      width: lerpDouble(collapsedWidth, expandedContentWidth, expansion),
      height: lerpDouble(collapsedHeight, expandedHeight, expansion),
      child: Stack(
        children: [
          Positioned(
            left: indicatorLeft,
            top: indicatorTop,
            child: Container(
              width: lerpDouble(collapsedPillWidth, expandedContentWidth, expansion),
              height: lerpDouble(collapsedIndicatorHeight, expandedHeight, expansion),
              decoration: _indicatorDecoration(t, focused: focused, expansion: expansion),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: SizedBox(
              width: expandedContentWidth,
              height: expandedHeight,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                child: _buildExpandedContent(context, t, labelOpacity: expansion, showLeading: false),
              ),
            ),
          ),
          Positioned(
            left: iconLeft,
            top: iconTop,
            child: SizedBox(
              width: iconSize,
              height: iconSize,
              child: Center(child: _leadingIcon(t)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = tokens(context);

    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, _) {
        final focused = focusNode.hasFocus && InputModeTracker.isKeyboardMode(context);
        final content = collapsedLabel == null
            ? SizedBox(
                width: expandedContentWidth,
                child: _buildExpandedLayout(context, t, focused: focused, fixedHeight: false),
              )
            : TweenAnimationBuilder<double>(
                tween: Tween(end: isCollapsed ? 0.0 : 1.0),
                duration: NavigationRailLayout.expandDuration,
                curve: NavigationRailLayout.expandCurve,
                builder: (context, expansion, _) =>
                    _buildMorphingLayouts(context, t, focused: focused, expansion: expansion),
              );
        return Focus(
          focusNode: focusNode,
          autofocus: autofocus,
          onKeyEvent: (node, event) => _handleRailItemKey(event, onSelect: onTap, onNavigateRight: onNavigateRight),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              mouseCursor: mouseCursor,
              onTap: onTap,
              borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
              child: UnconstrainedBox(
                alignment: .centerLeft,
                constrainedAxis: Axis.vertical,
                clipBehavior: Clip.hardEdge,
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }
}
