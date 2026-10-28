import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Native channel cancellation crosses the engine event loop. Drive both loops
// when a route now awaits teardown, as well as its rendering/transition frames.
Future<void> settlePlayer(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (var i = 0; i < 20; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pumpAndSettle();
}

/// Installs mock method/event channel handlers for a native player for the
/// duration of [testBody], then removes them.
Future<void> withMockPlayerChannels({
  required String methodChannelName,
  required String eventChannelName,
  Future<Object?> Function(MethodCall call)? methodHandler,
  Future<Object?> Function(MethodCall call)? eventHandler,
  required Future<void> Function() testBody,
}) async {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final methodChannel = MethodChannel(methodChannelName);
  final eventChannel = MethodChannel(eventChannelName);

  messenger.setMockMethodCallHandler(
    methodChannel,
    methodHandler ??
        (call) async {
          switch (call.method) {
            case 'initialize':
              return true;
            default:
              return null;
          }
        },
  );
  messenger.setMockMethodCallHandler(eventChannel, eventHandler ?? (call) async => null);

  try {
    await testBody();
  } finally {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockMethodCallHandler(eventChannel, null);
  }
}
