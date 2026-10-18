import '../ted/ted_joint_watch.dart';
import '../ted/ted_user_watch.dart';
import '../ted/ted_user_avatar.dart';
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

    return LayoutBuilder(
      builder: (context, constraints) => Stack(
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
          if (showWatched && item.backend == MediaBackend.ted) ..._tedBadges(constraints.maxHeight, unwatched),
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
      ),
    );
  }

  List<Widget> _tedBadges(double artworkHeight, int? unwatched) {
    final joints = [
      for (final raw in (item.raw?['joint_watches'] as List? ?? const []))
        TedJointWatch.fromJson(Map<String, dynamic>.from(raw as Map)),
    ].where((watch) => watch.seen).toList();
    final people = [
      for (final raw in (item.raw?['user_watches'] as List? ?? const []))
        TedUserWatch.fromJson(Map<String, dynamic>.from(raw as Map)),
    ].where((watch) => watch.seen).toList();
    final top =
        size.checkInset +
        ((item.isWatched ||
                ((item.isPartiallyWatched || showUnviewedCount) &&
                    (item.isShow || item.isSeason) &&
                    (unwatched ?? 0) > 0))
            ? size.badgeSize + 4
            : 0);
    final peopleTop = top + joints.length * (size.badgeSize + 4);
    final bottom =
        size.checkInset + (item.hasActiveProgress || item.isSeason && item.isPartiallyWatched ? size.barMinHeight : 0);
    final normalHeight = size.badgeSize + 2;
    final minimumHeight = size == WatchedIndicatorSize.compact ? 20.0 : 22.0;
    final available = artworkHeight.isFinite ? artworkHeight - peopleTop - bottom : people.length * (normalHeight + 4);
    final fit = _PeopleBadgeLayout.fit(people.length, available, normalHeight, minimumHeight);
    final diameter = fit.height - 2;
    final fontSize = size.badgeFontSize * diameter / size.badgeSize;
    return [
      if (joints.isNotEmpty)
        Positioned(
          top: top,
          left: size.checkInset,
          right: size.checkInset,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final watch in joints) _JointBadge(watch: watch, size: size, episodes: item.isShow || item.isSeason),
            ],
          ),
        ),
      if (people.isNotEmpty)
        Positioned(
          top: peopleTop + fit.offset,
          left: size.checkInset,
          right: size.checkInset,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 4,
            children: [
              for (final watch in people.take(fit.visible))
                TedOtherWatchBadge(
                  watch: watch,
                  size: size,
                  episodes: item.isShow || item.isSeason,
                  diameter: diameter,
                  fontSize: fontSize,
                ),
              if (fit.hidden > 0)
                Tooltip(
                  message: '${fit.hidden} more ${fit.hidden == 1 ? "person" : "people"} watched this media',
                  child: Container(
                    height: fit.height,
                    constraints: BoxConstraints(minWidth: fit.height),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .85),
                      borderRadius: BorderRadius.circular(fit.height),
                      border: Border.all(color: Colors.white70),
                    ),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        '+${fit.hidden}',
                        style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
    ];
  }
}

class _PeopleBadgeLayout {
  final int visible, hidden;
  final double height, offset;
  const _PeopleBadgeLayout(this.visible, this.hidden, this.height, [this.offset = 0]);

  factory _PeopleBadgeLayout.fit(int count, double available, double normal, double minimum) {
    if (count == 0) return _PeopleBadgeLayout(0, 0, normal);
    final fitted = (available - 4 * (count - 1)) / count;
    if (fitted >= minimum) return _PeopleBadgeLayout(count, 0, fitted.clamp(minimum, normal));
    final slots = ((available + 4) / (minimum + 4)).floor().clamp(1, count);
    final visible = slots - 1;
    final height = ((available - 4 * visible) / slots).clamp(minimum, normal);
    return _PeopleBadgeLayout(visible, count - visible, height, (available - height).clamp(double.negativeInfinity, 0));
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

class TedOtherWatchBadge extends StatelessWidget {
  final TedUserWatch watch;
  final WatchedIndicatorSize size;
  final bool episodes;
  final double? diameter, fontSize;
  const TedOtherWatchBadge({
    super.key,
    required this.watch,
    required this.size,
    required this.episodes,
    this.diameter,
    this.fontSize,
  });
  @override
  Widget build(BuildContext context) {
    final badgeDiameter = diameter ?? size.badgeSize;
    final badgeFontSize = fontSize ?? size.badgeFontSize;
    final partialCount = episodes && watch.available > 0 && watch.watched < watch.available;
    final partialProgress = !episodes && watch.watched == 0 && watch.progress != null;
    final detail = partialCount
        ? '${watch.watched} / ${watch.available} episodes watched'
        : watch.watched > 0
        ? 'Watched'
        : partialProgress
        ? '${watch.progress!.round()}% playback progress'
        : 'Previously viewed';
    final label = partialCount
        ? '${watch.watched} / ${watch.available}'
        : partialProgress
        ? '${watch.progress!.round()}%'
        : null;
    return Semantics(
      label: '${watch.name}: $detail',
      child: Tooltip(
        message: '${watch.name}: $detail',
        excludeFromSemantics: true,
        child: Container(
          padding: EdgeInsets.only(right: label == null ? 0 : 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .85),
            borderRadius: BorderRadius.circular(badgeDiameter),
            border: Border.all(color: Colors.white.withValues(alpha: .7)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: badgeDiameter,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    TedUserAvatar(watch: watch, diameter: badgeDiameter - 4),
                    if (partialProgress)
                      Positioned.fill(
                        child: CircularProgressIndicator(
                          value: watch.progress! / 100,
                          strokeWidth: 2,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                  ],
                ),
              ),
              if (label != null)
                Text(
                  label,
                  style: TextStyle(color: Colors.white, fontSize: badgeFontSize, fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
