import '../ted/ted_joint_watch.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../services/settings_service.dart';
import '../theme/mono_tokens.dart';
import 'app_icon.dart';
import 'media_progress_bar.dart';
import 'unwatched_count_badge.dart';

/// Size preset for [WatchedIndicator]: [standard] for grid/poster cards,
/// [compact] for dense surfaces (folder tree rows, episode thumbnails).
/// Add a preset here instead of hand-rolling a new overlay variant.
enum WatchedIndicatorSize {
  standard(
    checkInset: 4,
    checkPadding: 4,
    checkIconSize: 16,
    badgeSize: 24,
    badgeFontSize: 12,
    barRadius: 8,
    barMinHeight: 4,
  ),
  compact(
    checkInset: 3,
    checkPadding: 2,
    checkIconSize: 12,
    badgeSize: 20,
    badgeFontSize: 10,
    barRadius: 6,
    barMinHeight: 3,
  );

  const WatchedIndicatorSize({
    required this.checkInset,
    required this.checkPadding,
    required this.checkIconSize,
    required this.badgeSize,
    required this.badgeFontSize,
    required this.barRadius,
    required this.barMinHeight,
  });

  final double checkInset;
  final double checkPadding;
  final double checkIconSize;
  final double badgeSize;
  final double badgeFontSize;
  final double barRadius;
  final double barMinHeight;
}

/// Watched/progress overlay for media artwork: watched checkmark,
/// unwatched-count pill (shows/seasons), active-progress bar, and season
/// completion bar. The single implementation behind every surface that
/// stamps watch state onto a poster/thumbnail. Callers that must react to
/// [SettingsService.showWatchedIndicators] or [SettingsService.showUnwatchedCount]
/// flipping wrap themselves in a [SettingsBuilder] on those prefs.
class WatchedIndicator extends StatelessWidget {
  final MediaItem item;
  final WatchedIndicatorSize size;

  /// Overrides the settings read for the unwatched-count pill — pass it when
  /// the caller already watches [SettingsService.showUnwatchedCount] so pill
  /// visibility updates reactively with the caller's rebuilds.
  final bool? showUnwatchedCount;

  /// Detail shelves may show remaining counts even before the first completion.
  final bool showUnviewedCount;

  const WatchedIndicator({
    super.key,
    required this.item,
    this.size = WatchedIndicatorSize.standard,
    this.showUnwatchedCount,
    this.showUnviewedCount = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool showCount = showUnwatchedCount ?? SettingsService.instance.read(SettingsService.showUnwatchedCount);
    final bool showWatched = SettingsService.instance.read(SettingsService.showWatchedIndicators);
    final hasActiveProgress = item.hasActiveProgress;
    final unwatched = item.unwatchedCount;
    final barRadius = BorderRadius.only(
      bottomLeft: Radius.circular(size.barRadius),
      bottomRight: Radius.circular(size.barRadius),
    );

    return Stack(
      children: [
        // Watched checkmark
        if (showWatched && item.isWatched && !hasActiveProgress)
          Positioned(
            top: size.checkInset,
            right: size.checkInset,
            child: Container(
              padding: EdgeInsets.all(size.checkPadding),
              decoration: BoxDecoration(
                color: tokens(context).text,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4)],
              ),
              child: AppIcon(Symbols.check_rounded, fill: 1, color: tokens(context).bg, size: size.checkIconSize),
            ),
          ),
        // Unwatched count for shows/seasons
        if (showCount &&
            !item.isWatched &&
            // TED discovery includes never-watched shows once their schedule
            // is cached. Only a partial watch should add a count to a poster.
            (item.backend != MediaBackend.ted || item.isPartiallyWatched || showUnviewedCount) &&
            (item.kind == MediaKind.show || item.kind == MediaKind.season) &&
            unwatched != null &&
            unwatched > 0)
          Positioned(
            top: size.checkInset,
            right: size.checkInset,
            child: UnwatchedCountBadge(
              count: item.backend == MediaBackend.ted ? item.viewedLeafCount ?? 0 : unwatched,
              total: item.backend == MediaBackend.ted ? item.leafWatchTotal : null,
              size: size.badgeSize,
              fontSize: size.badgeFontSize,
            ),
          ),
        if (showWatched && item.backend == MediaBackend.ted)
          Positioned(
            top:
                size.checkInset +
                ((item.isWatched ||
                        ((item.isPartiallyWatched || showUnviewedCount) &&
                            (item.isShow || item.isSeason) &&
                            (unwatched ?? 0) > 0))
                    ? size.badgeSize + 4
                    : 0),
            right: size.checkInset,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final raw in (item.raw?['joint_watches'] as List? ?? const []))
                  if (TedJointWatch.fromJson(Map<String, dynamic>.from(raw as Map)).seen)
                    _JointBadge(
                      watch: TedJointWatch.fromJson(Map<String, dynamic>.from(raw)),
                      size: size,
                      episodes: item.isShow || item.isSeason,
                    ),
              ],
            ),
          ),
        // Progress bar for partially watched content (episodes/movies)
        if (hasActiveProgress)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: barRadius,
              child: MediaProgressBar(
                viewOffset: item.viewOffsetMs!,
                duration: item.durationMs!,
                minHeight: size.barMinHeight,
              ),
            ),
          ),
        // Progress bar for seasons (viewed leaves / total leaves).
        if (item.isSeason && item.isPartiallyWatched)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: barRadius,
              child: LinearProgressIndicator(
                value: item.leafWatchFraction,
                backgroundColor: tokens(context).outline,
                valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                minHeight: size.barMinHeight,
              ),
            ),
          ),
      ],
    );
  }
}

class _JointBadge extends StatelessWidget {
  final TedJointWatch watch;
  final WatchedIndicatorSize size;
  final bool episodes;
  const _JointBadge({required this.watch, required this.size, required this.episodes});
  @override
  Widget build(BuildContext context) {
    final remaining = watch.available - watch.watched;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tooltip(
        message:
            '${watch.name}: ${remaining > 0 && episodes
                ? "${watch.watched} / ${watch.available} episodes watched"
                : watch.watched > 0
                ? "Watched"
                : "In progress"}',
        child: remaining > 0 && episodes
            ? UnwatchedCountBadge(
                count: watch.watched,
                total: watch.available,
                size: size.badgeSize,
                fontSize: size.badgeFontSize,
                backgroundColor: Color(int.parse(watch.color.substring(1), radix: 16) | 0xFF000000),
                foregroundColor: Colors.black,
              )
            : Container(
                width: size.badgeSize,
                height: size.badgeSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Color(int.parse(watch.color.substring(1), radix: 16) | 0xFF000000),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  watch.watched > 0 ? Icons.check : Icons.history,
                  color: Colors.black,
                  size: size.checkIconSize,
                ),
              ),
      ),
    );
  }
}
