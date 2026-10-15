import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_play_button.dart';
import 'ted_catalog_test.dart' show titleData;

void main() {
  final title = TedTitle.fromJson(titleData());
  Finder getButton() => find.descendant(of: find.byType(TedPlayButton), matching: find.byType(FilledButton));
  double scale(WidgetTester tester) => tester
      .widget<Transform>(find.descendant(of: find.byType(TedPlayButton), matching: find.byType(Transform)).first)
      .transform
      .storage[0];
  Future<void> mount(WidgetTester tester, {bool enabled = true, bool reducedMotion = false}) => tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: child!,
      ),
      home: Scaffold(
        body: Row(
          children: [
            TedPlayButton(title: title, onPressed: enabled ? () {} : null),
            TextButton(onPressed: () {}, child: const Text('Details')),
          ],
        ),
      ),
    ),
  );

  testWidgets('mouse hover pulses without changing layout and stops when the pointer leaves', (tester) async {
    await mount(tester);
    final layout = tester.getRect(find.byType(TedPlayButton));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse.moveTo(tester.getCenter(getButton()));
    await tester.pump();
    expect(scale(tester), closeTo(1.02, .001));
    await tester.pump(const Duration(milliseconds: 800));
    expect(scale(tester), closeTo(1.05, .001));
    await tester.pump(const Duration(milliseconds: 800));
    expect(scale(tester), closeTo(1.02, .001));
    expect(tester.getRect(find.byType(TedPlayButton)), layout);
    await mouse.moveTo(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(scale(tester), 1);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard focus pulses and stops on navigation or disabling an unavailable source', (tester) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(scale(tester), closeTo(1.02, .001));
    await tester.pump(const Duration(milliseconds: 800));
    expect(scale(tester), closeTo(1.05, .001));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(scale(tester), 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(scale(tester), greaterThan(1));
    await mount(tester, enabled: false);
    await tester.pumpAndSettle();
    expect(scale(tester), 1);
    expect(tester.widget<FilledButton>(getButton()).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps a steady focus cue and changing the preference stops the pulse', (tester) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await mount(tester, reducedMotion: true);
    await tester.pumpAndSettle();
    expect(scale(tester), closeTo(1.035, .001));
    await tester.pump(const Duration(seconds: 3));
    expect(scale(tester), closeTo(1.035, .001));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(scale(tester), 1);
    await mount(tester, enabled: false, reducedMotion: true);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(getButton()));
    await tester.pumpAndSettle();
    expect(scale(tester), 1);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
