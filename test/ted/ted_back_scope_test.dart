import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_back_scope.dart';
import 'package:plezy/focus/key_event_utils.dart';

void main() {
  testWidgets('visible IME gets first Back; next Back leaves the page', (tester) async {
    BackKeyCoordinator.clear();
    var backs = 0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        home: TedBackScope(
          onBack: () => backs++,
          child: const Scaffold(body: TextField(autofocus: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(backs, 0);
    expect(tester.testTextInput.isVisible, false);
    tester.view.resetViewInsets();
    await tester.pump();
    await tester.binding.handlePopRoute();
    expect(backs, 1);
  });
}
