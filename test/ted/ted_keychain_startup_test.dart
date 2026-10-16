import 'dart:io';
import 'package:plezy/focus/focusable_text_field.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/connectivity_probe.dart';
import 'package:plezy/ted/ted_app_shutdown.dart';
import 'package:plezy/ted/teddy_logs.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_profiles.dart';
import 'package:plezy/ted/ted_profile_screen.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_secure_storage_recovery.dart';
import 'package:plezy/teddy_main.dart';
import '../test_helpers/prefs.dart';
import 'ted_auth_test.dart' show pair;

void main() {
  // Initialize the static log queue outside a widget test’s disposable fake clock.
  setUpAll(TeddyLogs.close);
  setUp(resetSharedPreferencesForTest);
  for (final active in [false, true]) {
    testWidgets(
      'startup always offers saved profiles (previously active: $active), including after Keychain recovery',
      (tester) async {
        await SettingsService.getInstance();
        TvDetectionService.debugReset();
        await TvDetectionService.getInstance(forceTv: true);
        addTearDown(TvDetectionService.debugReset);
        final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('ted-keychain-test')))!;
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final store = TedLocalStore(db);
        final shutdown = TedAppShutdown(closeStorage: store.close);
        const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity_status');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          connectivity,
          (_) async => null,
        );
        addTearDown(() {
          ConnectivityProbe.resetForTesting();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            connectivity,
            null,
          );
        });
        addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
        final credentials = TedCredentials(
          tedServerUri('https://ted.example'),
          '11111111-1111-4111-8111-111111111111',
          TedTokens.fromJson(pair(DateTime.now().toUtc())),
        );
        var encoded = jsonEncode({
          'version': 1,
          'active': active ? tedProfileKey(credentials) : null,
          'profiles': [
            {'key': tedProfileKey(credentials), 'credentials': credentials.encode(), 'purging': false},
          ],
        });
        var denied = !active, reads = 0;
        const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          expect(call.method, 'read', reason: 'recovery must not reset existing credentials');
          reads++;
          if (denied) throw PlatformException(code: '-128');
          return call.arguments['key'] == TedProfiles.key ? encoded : null;
        });
        addTearDown(
          () =>
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: TedAppShutdownScope(
              shutdown: shutdown,
              child: TeddyHome(
                store: store,
                downloadRoot: root,
                deviceId: '11111111-1111-4111-8111-111111111111',
                profiles: TedProfiles(storage: const FlutterSecureStorage()),
              ),
            ),
          ),
        );
        Future<void> until(bool Function() ready) async {
          for (var i = 0; i < 100 && !ready(); i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
            await tester.pump();
          }
          expect(ready(), true);
        }

        if (!active) {
          await until(
            () =>
                find.byType(TedSecureStorageRecovery).evaluate().isNotEmpty &&
                !tester.widget<TedSecureStorageRecovery>(find.byType(TedSecureStorageRecovery)).busy,
          );
          expect(find.text('Sign in'), findsNothing);
          denied = false;
          await tester.tap(find.text('Retry secure storage'));
        }
        await until(
          () =>
              find.byType(TedProfileScreen).evaluate().isNotEmpty &&
              !tester.widget<TedProfileScreen>(find.byType(TedProfileScreen)).busy,
        );
        expect(find.text('Fixture'), findsOneWidget);
        expect(reads, greaterThan(0));
        expect(find.text('Who’s watching?'), findsOneWidget);
        expect(find.text('Sign in'), findsNothing);
        expect(find.byType(TedSecureStorageRecovery), findsNothing);
        // Adding a profile is an in-place screen, not a Navigator route.
        // System Back must return to the chooser instead of exiting the app.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          if (call.method == 'read') return call.arguments['key'] == TedProfiles.key ? encoded : null;
          if (call.method == 'write' && call.arguments['key'] == TedProfiles.key) {
            encoded = call.arguments['value'] as String;
          }
          return null;
        });
        const inputChannel = MethodChannel('com.plezy/text_input');
        final inputFocus = <bool>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(inputChannel, (
          call,
        ) async {
          if (call.method == 'setNativeTextInputFocused') inputFocus.add(call.arguments as bool);
          return null;
        });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            inputChannel,
            null,
          ),
        );
        await tester.tap(find.text('Add profile'));
        await until(() => find.text('Sign in').evaluate().isNotEmpty);
        expect(find.byType(FocusableTextField), findsNWidgets(3));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(TextField).at(1));
        await tester.pumpAndSettle();
        expect(inputFocus.last, isTrue, reason: 'native TV keyboard must own remote navigation');
        await tester.enterText(find.byType(TextField).at(1), 'remote-user');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Sign in'), findsOneWidget, reason: 'first Back only dismisses editing');
        expect(inputFocus.last, isFalse);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(TedProfileScreen), findsOneWidget);
        await tester.tap(find.text('Add profile'));
        await until(() => find.text('Sign in').evaluate().isNotEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(TedProfileScreen), findsOneWidget);
        var closed = false;
        final closing = shutdown.requestExit().then((_) => closed = true);
        await until(() => closed);
        await closing;
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.android}),
    );
  }
}
