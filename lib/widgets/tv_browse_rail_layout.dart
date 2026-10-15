import 'package:flutter/material.dart';
import '../focus/focus_theme.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../services/settings_service.dart';
import '../utils/layout_constants.dart';

class TvBrowseRailLayoutMetrics {
  final bool isPersonHub;
  final bool isMixedHub;
  final bool useWideLayout;
  final double focusExtra;
  final double railEdgePadding;
  final double itemGap;

  /// Whether the hub has a leading options card in the negative-offset region
  /// before the row's scroll anchor (see [TvBrowseRailLayout.minScrollExtentFor]).
  final bool hasLeading;
  final double cardWidth;
  final double posterWidth;
  final double posterHeight;
  final double containerHeight;
  final double height;

  const TvBrowseRailLayoutMetrics({
    required this.isPersonHub,
    required this.isMixedHub,
    required this.useWideLayout,
    required this.focusExtra,
    required this.railEdgePadding,
    required this.itemGap,
    this.hasLeading = false,
    required this.cardWidth,
    required this.posterWidth,
    required this.posterHeight,
    required this.containerHeight,
    required this.height,
  });
}

class TvBrowseRailLayout {
  static const double compactTallPosterScale = 0.8;
  static const double compactEpisodeThumbnailScale = compactTallPosterScale;
  static const double fullCardFocusScale = FocusTheme.fullCardFocusScale;

  static double scaleForSize(Size size) => TvLayoutConstants.scaleForSize(size);

  static double horizontalInsetForScale(double scale) => (24 * scale).clamp(18, 40).toDouble();

  static double railTopPaddingForScale(double scale) => 12 * scale;

  static double railBottomPaddingForScale(double scale) => 8 * scale;

  static double railInteractionExpansionForScale(double scale) => (12 * scale).clamp(8, 18).toDouble();

  static double fullCardItemGapForScale(double scale) => (12 * scale).clamp(8, 18).toDouble();

  static double hubStripHeightForScale(double scale) => 30 * scale;

  static double nextHubPeekHeightForScale(double scale) => 20 * scale;

  static double hubSectionHeightFor({required double scale, required double activeRailHeight}) {
    return hubStripHeightForScale(scale) + activeRailHeight;
  }

  static double viewportHeightFor({required int hubCount, required double scale, required double sectionHeight}) {
    final peekHeight = hubCount > 1 ? nextHubPeekHeightForScale(scale) : 0.0;
    return sectionHeight + peekHeight;
  }

  static bool isPersonHub(MediaHub hub) => hub.type == 'person';

  static double cardWidthFor({
    required double availableWidth,
    required int density,
    required bool useWideLayout,
    required double scale,
    required double horizontalPadding,
    required double itemGap,
  }) {
    final f = LibraryDensity.factor(density);
    final minWidth = (useWideLayout ? 280 : 170) * scale;
    final maxWidth = (useWideLayout ? 420 : 250) * scale;
    final targetCards = useWideLayout ? 4.2 - (f * 1.4) : 7.0 - (f * 2.0);
    final usableWidth = (availableWidth - horizontalPadding).clamp(1.0, double.infinity).toDouble();
    final gapCount = targetCards > 1 ? targetCards - 1 : 0.0;
    final fittedWidth = (usableWidth - (itemGap * gapCount)) / targetCards;
    return fittedWidth.clamp(minWidth, maxWidth).toDouble();
  }

  static TvBrowseRailLayoutMetrics metricsForHub({
    required MediaHub hub,
    required double availableWidth,
    required int density,
    required EpisodePosterMode episodePosterMode,
    required double scale,
    bool fullCardLayout = false,
    GridSpacing gridSpacing = GridSpacing.tight,
    double tallPosterScale = 1.0,
    double widePosterScale = 1.0,
    bool hasLeading = false,
  }) {
    final focusExtra = FocusTheme.focusBorderWidth * 2 * scale;
    final railEdgePadding = focusExtra + (12 * scale);
    // Full-card rails keep their own scale-derived gutter, like full-bleed
    // grids; every other rail follows the user's grid-spacing setting, scaled
    // with the rest of the rail metrics (#2226).
    final itemGap = fullCardLayout ? fullCardItemGapForScale(scale) : gridSpacing.gridGap * scale;
    final isPersonHub = TvBrowseRailLayout.isPersonHub(hub);
    final emptyEpisodeThumbnailHub =
        hub.items.isEmpty && hub.type == 'episode' && episodePosterMode == EpisodePosterMode.episodeThumbnail;
    final hasWide =
        !isPersonHub &&
        (emptyEpisodeThumbnailHub || hub.items.any((item) => item.usesWideAspectRatio(episodePosterMode)));
    final hasTall = !isPersonHub && hub.items.any((item) => !item.usesWideAspectRatio(episodePosterMode));
    final isMixedHub = hasWide && hasTall;
    final useWideLayout = hasWide && (!hasTall || episodePosterMode == EpisodePosterMode.episodeThumbnail);
    // Music hubs render square album/artist artwork (person hubs are already square).
    final isSquareHub =
        !isPersonHub &&
        hub.items.isNotEmpty &&
        hub.items.every((item) => item.cardShape(episodePosterMode) == CardShape.square);
    final baseCardWidth = cardWidthFor(
      availableWidth: availableWidth,
      density: density,
      useWideLayout: useWideLayout,
      scale: scale,
      horizontalPadding: railEdgePadding * 2,
      itemGap: itemGap,
    );
    final cardWidth = baseCardWidth * (useWideLayout ? widePosterScale : tallPosterScale);
    final posterWidth = fullCardLayout ? cardWidth : cardWidth - (6 * scale);
    final posterHeight = (isPersonHub || isSquareHub)
        ? posterWidth
        : (useWideLayout ? posterWidth * 9 / 16 : posterWidth * 1.5);
    final labelHeight = fullCardLayout ? 0.0 : ((isPersonHub ? 52 : 36) * scale);
    final containerHeight = (posterHeight + labelHeight).ceilToDouble();
    final height = containerHeight + focusExtra + (10 * scale);

    return TvBrowseRailLayoutMetrics(
      isPersonHub: isPersonHub,
      isMixedHub: isMixedHub,
      useWideLayout: useWideLayout,
      focusExtra: focusExtra,
      railEdgePadding: railEdgePadding,
      itemGap: itemGap,
      hasLeading: hasLeading,
      cardWidth: cardWidth,
      posterWidth: posterWidth,
      posterHeight: posterHeight,
      containerHeight: containerHeight,
      height: height,
    );
  }

  static double maxActiveRailHeight({
    required List<MediaHub> hubs,
    required double availableWidth,
    required int density,
    required EpisodePosterMode episodePosterMode,
    EpisodePosterMode Function(MediaHub hub)? episodePosterModeForHub,
    double Function(MediaHub hub)? widePosterScaleForHub,
    required double scale,
    bool fullCardLayout = false,
    GridSpacing gridSpacing = GridSpacing.tight,
    double tallPosterScale = 1.0,
    double widePosterScale = 1.0,
  }) {
    var maxHeight = 0.0;
    for (final hub in hubs) {
      final metrics = metricsForHub(
        hub: hub,
        availableWidth: availableWidth,
        density: density,
        episodePosterMode: episodePosterModeForHub?.call(hub) ?? episodePosterMode,
        scale: scale,
        fullCardLayout: fullCardLayout,
        gridSpacing: gridSpacing,
        tallPosterScale: tallPosterScale,
        widePosterScale: widePosterScaleForHub?.call(hub) ?? widePosterScale,
      );
      if (metrics.height > maxHeight) maxHeight = metrics.height;
    }
    return maxHeight;
  }

  static double estimatedMaxScrollExtent({
    required MediaHub hub,
    required TvBrowseRailLayoutMetrics metrics,
    required double viewportWidth,
    bool? hasTrailing,
  }) {
    final showTrailing = hasTrailing ?? hub.more;
    final itemCount = hub.items.length + (showTrailing ? 1 : 0);
    // The leading options card lives BEFORE the scroll anchor (negative
    // offsets, see [minScrollExtentFor]); it never contributes here.
    final contentWidth = (metrics.railEdgePadding * 2) + (itemCount * (metrics.cardWidth + metrics.itemGap));
    return (contentWidth - viewportWidth).clamp(0.0, double.infinity).toDouble();
  }

  /// Scroll extent of the region before the anchor: the hub's leading options
  /// card plus its edge padding. Zero for hubs without a leading slot, so the
  /// row rests with its first item at the rail start and the options card
  /// sits off-screen until focus (or a drag) reveals it.
  static double minScrollExtentFor(TvBrowseRailLayoutMetrics metrics) =>
      metrics.hasLeading ? -(metrics.railEdgePadding + metrics.cardWidth) : 0.0;

  static double itemExtentForIndex({required int index, required TvBrowseRailLayoutMetrics metrics}) {
    assert(index >= 0);
    return metrics.cardWidth + metrics.itemGap;
  }

  static double scrollOffsetForIndex({
    required MediaHub hub,
    required int index,
    required TvBrowseRailLayoutMetrics metrics,
    required double viewportWidth,
    required double maxScrollExtent,
    bool? hasTrailing,
  }) {
    final showTrailing = hasTrailing ?? hub.more;
    final leadingCount = metrics.hasLeading ? 1 : 0;
    final totalCount = leadingCount + hub.items.length + (showTrailing ? 1 : 0);
    if (totalCount == 0) return 0;

    final clampedIndex = index.clamp(0, totalCount - 1).toInt();
    if (metrics.hasLeading && clampedIndex == 0) return minScrollExtentFor(metrics);
    final itemExtent = metrics.cardWidth + metrics.itemGap;
    final targetCenter = metrics.railEdgePadding + ((clampedIndex - leadingCount + 0.5) * itemExtent);
    return (targetCenter - (viewportWidth / 2)).clamp(0.0, maxScrollExtent).toDouble();
  }

  static double estimateHeight({
    required Size size,
    required List<MediaHub> hubs,
    required int density,
    required EpisodePosterMode episodePosterMode,
    EpisodePosterMode Function(MediaHub hub)? episodePosterModeForHub,
    double Function(MediaHub hub)? widePosterScaleForHub,
    bool fullCardLayout = false,
    GridSpacing gridSpacing = GridSpacing.tight,
    double tallPosterScale = 1.0,
    double widePosterScale = 1.0,
  }) {
    if (hubs.isEmpty) return 0;

    final scale = scaleForSize(size);
    final availableWidth = size.width - horizontalInsetForScale(scale);
    if (availableWidth <= 0) return 0;

    final railHeight = maxActiveRailHeight(
      hubs: hubs,
      availableWidth: availableWidth,
      density: density,
      episodePosterMode: episodePosterMode,
      episodePosterModeForHub: episodePosterModeForHub,
      widePosterScaleForHub: widePosterScaleForHub,
      scale: scale,
      fullCardLayout: fullCardLayout,
      gridSpacing: gridSpacing,
      tallPosterScale: tallPosterScale,
      widePosterScale: widePosterScale,
    );

    final sectionHeight = hubSectionHeightFor(scale: scale, activeRailHeight: railHeight);

    return railTopPaddingForScale(scale) +
        viewportHeightFor(hubCount: hubs.length, scale: scale, sectionHeight: sectionHeight) +
        railBottomPaddingForScale(scale);
  }
}
