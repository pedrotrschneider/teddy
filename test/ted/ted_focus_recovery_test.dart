import 'package:flutter/material.dart';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_focus_recovery.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/utils/platform_detector.dart';

void main() {
  setUp(() {
    TvDetectionService.debugSetAppleTVOverride(true);
    PlatformDetector.debugSetIsDesktopOSOverride(false);
  });
  tearDown(() {
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsDesktopOSOverride(null);
  });
  testWidgets('lost focus and app activation restore the remembered control; valid focus stays put', (tester) async {
    final routes = TedFocusRoutes();
    final first = FocusNode(), second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [routes],
        builder: (_, child) => TedFocusRecovery(routes: routes, child: child!),
        home: Scaffold(
          body: Row(
            children: [
              TextButton(focusNode: first, onPressed: () {}, child: const Text('First')),
              TextButton(focusNode: second, onPressed: () {}, child: const Text('Second')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    second.requestFocus();
    await tester.pump();
    FocusManager.instance.rootScope.requestFocus();
    await tester.pumpAndSettle();
    expect(second.hasPrimaryFocus, true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(second.hasPrimaryFocus, true);
    first.requestFocus();
    await tester.pumpAndSettle();
    expect(first.hasPrimaryFocus, true);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('TV mouse activity never restores or steals focus; keyboard activation still restores it', (
    tester,
  ) async {
    final routes = TedFocusRoutes();
    final button = FocusNode();
    addTearDown(button.dispose);
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          navigatorObservers: [routes],
          builder: (_, child) => TedFocusRecovery(routes: routes, child: child!),
          home: Scaffold(
            body: TextButton(focusNode: button, onPressed: () {}, child: const Text('Button')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    button.requestFocus();
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(200, 200));
    await mouse.moveTo(const Offset(210, 200));
    await tester.pumpAndSettle();
    expect(button.hasPrimaryFocus, true);
    expect(InputModeTracker.currentMode, InputMode.pointer);
    button.unfocus();
    await tester.pumpAndSettle();
    expect(button.hasPrimaryFocus, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(button.hasPrimaryFocus, false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(button.hasPrimaryFocus, true);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('a dialog owns restoration and Escape; underlying defaults cannot steal focus', (tester) async {
    final routes = TedFocusRoutes();
    final page = FocusNode(), dialog = FocusNode();
    addTearDown(page.dispose);
    addTearDown(dialog.dispose);
    var defaults = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [routes],
        builder: (_, child) => TedFocusRecovery(routes: routes, child: child!),
        home: Builder(
          builder: (context) => TedDefaultFocus(
            restore: () {
              defaults++;
              page.requestFocus();
            },
            child: Scaffold(
              body: TextButton(
                focusNode: page,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => Focus(
                    onKeyEvent: (_, event) {
                      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                        Navigator.of(context).pop();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: AlertDialog(
                      content: TextButton(
                        focusNode: dialog,
                        autofocus: true,
                        onPressed: () {},
                        child: const Text('Dialog'),
                      ),
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final before = defaults;
    FocusManager.instance.rootScope.requestFocus();
    await tester.pumpAndSettle();
    expect(dialog.hasPrimaryFocus, true);
    expect(defaults, before);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Dialog'), findsNothing);
    expect(page.hasPrimaryFocus, true);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('a hidden-controls player surface remains a valid remembered focus owner for Escape', (tester) async {
    final routes = TedFocusRoutes();
    final surface = FocusNode(skipTraversal: true);
    addTearDown(surface.dispose);
    var escapes = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [routes],
        builder: (_, child) => TedFocusRecovery(routes: routes, child: child!),
        home: Scaffold(
          body: Focus(
            focusNode: surface,
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                escapes++;
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: ExcludeFocus(
              child: TextButton(onPressed: () {}, child: const Text('Hidden control')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(surface.hasPrimaryFocus, true);
    FocusManager.instance.rootScope.requestFocus();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(surface.hasPrimaryFocus, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(escapes, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
