import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openTedProfileMenu(WidgetTester tester) async {
  await tester.tap(
    find.byWidgetPredicate((widget) => widget is Tooltip && widget.message?.startsWith('Profile: ') == true),
  );
  await tester.pumpAndSettle();
}

Future<void> chooseTedDiscoverType(WidgetTester tester, String label) async {
  final type = find.byKey(const ValueKey('discover-type'));
  await tester.ensureVisible(type);
  await tester.tap(type);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}
