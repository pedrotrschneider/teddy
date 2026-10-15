import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_secure_storage_recovery.dart';

void main() {
  testWidgets('Keychain retry is keyboard accessible and cannot be repeated while waiting', (tester) async {
    var attempts = 0;
    Future<void> show(bool busy) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TedSecureStorageRecovery(busy: busy, onRetry: () => attempts++),
        ),
      ),
    );
    await show(true);
    await tester.pump();
    await show(false);
    await tester.pumpAndSettle();
    expect(find.text('Retry Keychain access'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(attempts, 1);
    await show(true);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(attempts, 1);
    await show(false);
    await tester.tap(find.text('Retry Keychain access'));
    expect(attempts, 2);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
}
