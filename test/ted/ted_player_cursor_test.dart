import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_player_cursor.dart';

void main() {
  testWidgets('idle cursor hides in a player boundary without consuming clicks and returns on movement', (
    tester,
  ) async {
    var clicks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TedPlayerCursor(
            child: Center(
              child: TextButton(onPressed: () => clicks++, child: const Text('Control')),
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.moveTo(const Offset(100, 100));
    await tester.pump(const Duration(seconds: 3));
    expect(find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.none), findsOneWidget);
    await tester.tap(find.text('Control'));
    expect(clicks, 1);
    await mouse.moveTo(const Offset(110, 100));
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.none), findsNothing);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  });
}
