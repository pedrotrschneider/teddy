import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/media_progress_bar.dart';
import 'package:plezy/widgets/unwatched_count_badge.dart';
import 'package:plezy/widgets/watched_indicator.dart';
import 'package:plezy/ted/ted_profile_avatar.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  Future<void> pump(WidgetTester tester, WatchedIndicator indicator) => tester.pumpWidget(
    MaterialApp(
      theme: monoTheme(dark: true),
      home: SizedBox(width: 200, height: 300, child: indicator),
    ),
  );

  final watchedMovie = testMediaItem(id: 'movie', kind: MediaKind.movie, viewCount: 1);

  testWidgets('shows the watched checkmark by default', (tester) async {
    await pump(tester, WatchedIndicator(item: watchedMovie));

    expect(find.byIcon(Symbols.check_rounded), findsOneWidget);
  });

  testWidgets('TED joint badges stack on the right without changing personal completion', (tester) async {
    final item = testMediaItem(
      backend: MediaBackend.ted,
      kind: MediaKind.show,
      leafCount: 10,
      viewedLeafCount: 2,
      raw: {
        'joint_watches': [
          {
            'account_id': 7,
            'name': 'Home',
            'color': '#59C6F2',
            'watch': {'seen': true, 'watched': 10, 'available': 10, 'progress': null},
          },
          {
            'account_id': 8,
            'name': 'Friends',
            'color': '#F4BE52',
            'watch': {'seen': true, 'watched': 3, 'available': 10, 'progress': null},
          },
        ],
      },
    );
    await pump(tester, WatchedIndicator(item: item));
    expect(find.text('2 / 10'), findsOneWidget);
    expect(find.text('3 / 10'), findsOneWidget);
    expect(find.byIcon(Symbols.check_rounded), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
    final own = tester.getTopRight(find.byType(UnwatchedCountBadge).first);
    final home = tester.getTopRight(find.byTooltip('Home: Watched'));
    final friends = tester.getTopRight(find.byTooltip('Friends: 3 / 10 episodes watched'));
    expect(own.dx, greaterThan(500));
    expect(home.dx, own.dx);
    expect(friends.dx, own.dx);
    expect(home.dy, greaterThan(own.dy));
    expect(friends.dy, greaterThan(home.dy));
  });

  for (final sample in [
    (height: 300.0, people: 3, visible: 3, hidden: 0, shrink: false),
    (height: 148.0, people: 4, visible: 4, hidden: 0, shrink: true),
    (height: 113.0, people: 4, visible: 1, hidden: 3, shrink: false),
  ]) {
    testWidgets('peer column fits ${sample.height}px artwork with ${sample.hidden} hidden people', (tester) async {
      final item = testMediaItem(
        backend: MediaBackend.ted,
        kind: MediaKind.episode,
        viewCount: 1,
        raw: {
          'joint_watches': [
            {
              'account_id': 7,
              'name': 'Home',
              'color': '#59C6F2',
              'watch': {'seen': true, 'watched': 1, 'available': 1, 'progress': null},
            },
          ],
          'user_watches': [
            for (var i = 0; i < sample.people; i++)
              {
                'account_id': i + 10,
                'name': 'Person $i',
                'watch': {'seen': true, 'watched': 0, 'available': 1, 'progress': 25.0},
              },
          ],
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          home: Center(
            child: SizedBox(
              width: 200,
              height: sample.height,
              child: WatchedIndicator(item: item, size: WatchedIndicatorSize.compact),
            ),
          ),
        ),
      );
      expect(find.byType(TedProfileAvatar), findsNWidgets(sample.visible));
      expect(find.text('25%'), findsNWidgets(sample.visible));
      final bounds = tester.getRect(find.byType(WatchedIndicator));
      var previous = tester.getRect(find.byTooltip('Home: Watched'));
      for (var i = 0; i < sample.visible; i++) {
        final badge = find.byType(TedOtherWatchBadge).at(i);
        final rect = tester.getRect(badge);
        expect(rect.right, previous.right);
        expect(rect.top, greaterThan(previous.bottom));
        expect(bounds.contains(rect.topLeft), isTrue);
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom - 3));
        final diameter = tester.widget<TedOtherWatchBadge>(badge).diameter!;
        expect(diameter, sample.shrink ? lessThan(20) : 20);
        expect(diameter, greaterThanOrEqualTo(18));
        previous = rect;
      }
      if (sample.hidden > 0) {
        final overflow = find.byTooltip('${sample.hidden} more people watched this media');
        expect(find.text('+${sample.hidden}'), findsOneWidget);
        final rect = tester.getRect(overflow);
        expect(rect.right, previous.right);
        expect(rect.top, greaterThan(previous.bottom));
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom - 3));
      } else {
        expect(find.textContaining('+'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('personal and joint episode ratios share expanding pill geometry', (tester) async {
    for (final size in WatchedIndicatorSize.values) {
      for (final (watched, total) in [(1234, 5678), (0, 1)]) {
        final item = testMediaItem(
          backend: MediaBackend.ted,
          kind: MediaKind.season,
          leafCount: total,
          viewedLeafCount: watched,
          raw: {
            'joint_watches': [
              {
                'account_id': 7,
                'name': 'Home',
                'color': '#59C6F2',
                'watch': {'seen': true, 'watched': watched, 'available': total, 'progress': null},
              },
            ],
          },
        );
        await pump(tester, WatchedIndicator(item: item, size: size, showUnviewedCount: true));
        final badges = find.byType(UnwatchedCountBadge);
        expect(badges, findsNWidgets(2));
        expect(find.text('$watched / $total'), findsNWidgets(2));
        final own = tester.getRect(badges.first), joint = tester.getRect(badges.last);
        expect(own.size, joint.size);
        expect(own.width, greaterThan(size.badgeSize));
        expect(own.height, size.badgeSize);
        expect(joint.right, own.right);
        expect(joint.top, greaterThanOrEqualTo(own.bottom));
        for (final badge in [badges.first, badges.last]) {
          final label = find.descendant(of: badge, matching: find.byType(Text));
          final rect = tester.getRect(label);
          expect(rect.left, greaterThanOrEqualTo(tester.getRect(badge).left));
          expect(rect.right, lessThanOrEqualTo(tester.getRect(badge).right));
        }
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('hides only the checkmark when watched indicators are off (#1998)', (tester) async {
    await SettingsService.instance.write(SettingsService.showWatchedIndicators, false);
    final partiallyWatchedShow = testMediaItem(id: 'show', kind: MediaKind.show, leafCount: 10, viewedLeafCount: 4);
    final inProgressMovie = testMediaItem(
      id: 'movie-2',
      kind: MediaKind.movie,
      durationMs: 100000,
      viewOffsetMs: 50000,
    );

    await pump(tester, WatchedIndicator(item: watchedMovie));
    expect(find.byIcon(Symbols.check_rounded), findsNothing);

    await pump(tester, WatchedIndicator(item: partiallyWatchedShow));
    expect(find.byType(UnwatchedCountBadge), findsOneWidget, reason: 'unwatched counts are a separate pref');

    await pump(tester, WatchedIndicator(item: inProgressMovie));
    expect(find.byType(MediaProgressBar), findsOneWidget, reason: 'progress bars are not indicators');
  });
}
