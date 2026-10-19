import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/focus_theme.dart';
import 'package:plezy/ted/ted_browse_header.dart';
import 'package:plezy/ted/ted_profile_avatar.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import 'ted_profile_pictures_test.dart' show picture;

void main() {
  for (final withPicture in [false, true]) {
    testWidgets('sidebar ${withPicture ? "photo" : "initial"} stays circular through collapse and expansion', (
      tester,
    ) async {
      final image = withPicture ? await tester.runAsync(picture) : null;
      var collapsed = true;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                return Center(
                  child: SizedBox(
                    width: collapsed ? 72 : 196,
                    child: TedSidebarControls(
                      collapsed: collapsed,
                      displayName: 'Pedro',
                      profilePicture: image,
                      onReload: () {},
                      onSettings: () {},
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      void checkCircle() {
        final circle = find.descendant(of: find.byType(TedProfileAvatar), matching: find.byType(ClipOval));
        final bounds = tester.getRect(circle);
        expect(bounds.width, closeTo(bounds.height, .01));
        // The 32px pill reserves its 2.5px focus border on both sides.
        final available = NavigationRailItem.collapsedIndicatorHeight - 2 * FocusTheme.focusBorderWidth;
        expect(bounds.width, greaterThanOrEqualTo(available));
        expect(bounds.width, lessThanOrEqualTo(32));
        if (!withPicture) expect((tester.getCenter(find.text('P')) - bounds.center).distance, lessThan(.1));
        expect(tester.takeException(), isNull);
      }

      await tester.pumpAndSettle();
      checkCircle();
      for (final value in [false, true]) {
        change(() => collapsed = value);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        checkCircle();
        await tester.pumpAndSettle();
        checkCircle();
      }
      if (withPicture) expect(find.byType(Image), findsOneWidget);
    });
  }

  testWidgets('a tightly constrained avatar centers a circle instead of stretching its clip', (tester) async {
    for (final bounds in [const Size(64, 24), const Size(24, 64)]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.fromSize(
              size: bounds,
              child: const TedProfileAvatar(name: 'Pedro', diameter: 32),
            ),
          ),
        ),
      );
      final circle = tester.getRect(find.byType(ClipOval));
      expect(circle.size, const Size(24, 24));
      expect(circle.center, tester.getCenter(find.byType(TedProfileAvatar)));
      expect(tester.takeException(), isNull);
    }
  });
}
