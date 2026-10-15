import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/ted/ted_profile_screen.dart';
import 'package:plezy/ted/ted_profiles.dart';
import 'package:plezy/ted/ted_models.dart';
import 'ted_auth_test.dart' show pair;

TedSavedProfile profile(int id, {String server = 'https://ted.example', bool purging = false}) {
  final tokens = pair(DateTime.utc(2026, 10, 14), userId: id);
  tokens['user'] = {'id': id, 'display_name': 'Profile $id'};
  final credentials = TedCredentials(
    tedServerUri(server),
    '11111111-1111-4111-8111-111111111111',
    TedTokens.fromJson(tokens),
  );
  return TedSavedProfile(tedProfileKey(credentials), credentials, purging: purging);
}

Widget chooser(List<TedSavedProfile> profiles, ValueChanged<String> select, {bool busy = false}) => InputModeTracker(
  child: MaterialApp(
    home: Scaffold(
      body: TedProfileScreen(
        snapshot: TedProfileSnapshot(null, profiles),
        server: tedServerUri('https://ted.example').toString(),
        busy: busy,
        error: null,
        onSelect: (p) => select(p.name),
        onServer: (s) => select(s!),
        onAdd: () => select('add'),
        onChangeServer: () => select('server'),
      ),
    ),
  ),
);

void main() {
  testWidgets('horizontal profile selection, plus tile and saved-server controls remain keyboard accessible', (
    tester,
  ) async {
    var chosen = '';
    await tester.pumpWidget(
      chooser([
        profile(1),
        profile(2),
        profile(3, purging: true),
        profile(4, server: 'https://other.example'),
      ], (value) => chosen = value),
    );
    await tester.pumpAndSettle();
    expect(find.text('Who’s watching?'), findsOneWidget);
    expect(find.text('Profile 3'), findsNothing);
    expect(find.text('Profile 4'), findsNothing);
    expect(tester.getCenter(find.text('Profile 1')).dy, tester.getCenter(find.text('Profile 2')).dy);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(chosen, 'Profile 2');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(chosen, 'add');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(tedServerUri('https://other.example').toString()), findsWidgets);
  });

  testWidgets('narrow chooser wraps; hover preserves focus and clicking the name selects', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var chosen = '';
    await tester.pumpWidget(chooser([profile(1), profile(2)], (value) => chosen = value));
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('Add profile')).dy, greaterThan(tester.getCenter(find.text('Profile 1')).dy));
    final focus = FocusManager.instance.primaryFocus;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Profile 2')));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, focus);
    await tester.tap(find.text('Profile 2'));
    expect(chosen, 'Profile 2');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(chosen, 'add');
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
  });

  testWidgets('empty chooser focuses Add profile and busy state blocks activation', (tester) async {
    var calls = 0;
    await tester.pumpWidget(chooser([], (_) => calls++));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls, 1);
    await tester.pumpWidget(chooser([], (_) => calls++, busy: true));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
