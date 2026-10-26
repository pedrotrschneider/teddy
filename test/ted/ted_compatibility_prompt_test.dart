import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_compatibility.dart';
import 'package:plezy/ted/ted_compatibility_prompt.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/teddy_update_settings.dart';
import 'package:plezy/ted/teddy_updates.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../test_helpers/prefs.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'teddy_updates_test.dart' show release;

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });

  TedAuth connection({String? contract = '0.4'}) {
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => DateTime.utc(2026, 10, 10),
      client: MockClient(
        (_) async => http.Response(
          '{"code":"incompatible_version"}',
          426,
          headers: {'x-ted-compatibility-version': ?contract},
        ),
      ),
    );
    addTearDown(auth.close);
    return auth;
  }

  Future<void> rejectLogin(TedAuth auth) => expectLater(
    auth.login('https://ted.example', 'fixture', '', 'test'),
    throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'incompatible_version')),
  );

  Widget page(TedAuth auth, TeddyUpdateCheck checker, {Widget? child}) => InputModeTracker(
    child: MaterialApp(
      theme: monoTheme(dark: true),
      home: TedCompatibilityPrompt(
        auth: auth,
        downloadRoot: '/fixture/downloads',
        currentVersion: '0.3.1',
        checkForUpdates: checker,
        child: child ?? const Scaffold(body: Text('Profile screen')),
      ),
    ),
  );

  final dialogUpdate = find.descendant(of: find.byType(AlertDialog), matching: find.text('Update Teddy'));

  testWidgets('incompatibility offers keyboard update to the required family and retains the chosen channel', (
    tester,
  ) async {
    final auth = connection();
    final checks = <({String current, bool candidates, TedCompatibility? target})>[];
    Future<TeddyUpdate?> check(String current, bool candidates, {TedCompatibility? requiredCompatibility}) async {
      checks.add((current: current, candidates: candidates, target: requiredCompatibility));
      return TeddyUpdates.select(
        [release('0.3.2'), release('0.4.0'), release('0.4.1-rc1'), release('0.5.0')],
        current,
        candidates,
        requiredCompatibility: requiredCompatibility,
      );
    }

    await tester.pumpWidget(page(auth, check));
    await rejectLogin(auth);
    await tester.pumpAndSettle();
    expect(find.text('Update required'), findsOneWidget);
    expect(dialogUpdate, findsOneWidget);
    expect(checks, isEmpty, reason: 'Discovery starts only after choosing Update Teddy.');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(checks.single.current, '0.3.1');
    expect(checks.single.candidates, false);
    expect(checks.single.target.toString(), '0.4');
    expect(find.text('Update to version 0.4.0'), findsOneWidget);
    await SettingsService.instance.write(SettingsService.teddyUpdateChannel, 'rc');
    await tester.pumpAndSettle();
    expect(checks.last.candidates, true);
    expect(checks.last.target.toString(), '0.4');
    expect(find.text('Update to version 0.4.1-rc1'), findsOneWidget);
    expect(find.text('Update to version 0.5.0'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Profile screen'), findsOneWidget);
    expect(find.text('Update Teddy'), findsOneWidget, reason: 'Dismissal must not lose the direct upgrade action.');
    await tester.tap(find.text('Update Teddy'));
    await tester.pumpAndSettle();
    expect(find.text('Update to version 0.4.1-rc1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved-account background failure opens the prompt without a sign-in attempt', (tester) async {
    final store = MemoryStore();
    final now = DateTime.utc(2026, 10, 10);
    var incompatible = false;
    final auth = TedAuth(
      store: store,
      now: () => now,
      client: MockClient((_) async {
        if (!incompatible) return response(pair(now));
        return http.Response('{"code":"incompatible_version"}', 426, headers: {'x-ted-compatibility-version': '0.4'});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    await tester.pumpWidget(page(auth, (_, _, {requiredCompatibility}) async => null));
    incompatible = true;
    await expectLater(auth.profilePicture(), throwsA(isA<TedFailure>()));
    await tester.pumpAndSettle();
    expect(find.text('Update required'), findsOneWidget);
    expect(dialogUpdate, findsOneWidget);
    expect(auth.signedIn, true);
    expect(store.saved!.refreshPending, false);
    // Repeated background errors neither stack dialogs nor reopen a dismissed one.
    await expectLater(auth.profilePicture(), throwsA(isA<TedFailure>()));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    await expectLater(auth.profilePicture(), throwsA(isA<TedFailure>()));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Update Teddy'), findsOneWidget);
  });

  testWidgets('switching connections dismisses only its own prompt and fences a held update check', (tester) async {
    final auth = connection();
    final replacement = connection();
    final answer = Completer<TeddyUpdate?>();
    Future<TeddyUpdate?> check(String current, bool candidates, {TedCompatibility? requiredCompatibility}) =>
        answer.future;
    final navigator = GlobalKey<NavigatorState>();
    late StateSetter change;
    var active = auth;
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          navigatorKey: navigator,
          theme: monoTheme(dark: true),
          home: StatefulBuilder(
            builder: (context, setState) {
              change = setState;
              return TedCompatibilityPrompt(
                auth: active,
                downloadRoot: '/fixture/downloads',
                currentVersion: '0.3.1',
                checkForUpdates: check,
                child: const Scaffold(body: Text('Profile screen')),
              );
            },
          ),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Existing details route'))),
      ),
    );
    await tester.pumpAndSettle();
    await rejectLogin(auth);
    await tester.pumpAndSettle();
    expect(find.text('Update required'), findsOneWidget);
    await tester.tap(dialogUpdate);
    await tester.pump();
    expect(find.text('Checking for updates…'), findsOneWidget);
    auth.close();
    change(() => active = replacement);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Existing details route'), findsOneWidget);
    answer.complete(
      TeddyUpdates.select([release('0.4.0')], '0.3.1', false, requiredCompatibility: TedCompatibility.parse('0.4')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Update to version 0.4.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal settings does not pass a cross-version target', (tester) async {
    final targets = <TedCompatibility?>[];
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TeddyUpdateSettings(
                currentVersion: '0.3.1',
                checkForUpdates: (current, candidates, {requiredCompatibility}) async {
                  targets.add(requiredCompatibility);
                  return TeddyUpdates.select(
                    [release('0.4.0')],
                    current,
                    candidates,
                    requiredCompatibility: requiredCompatibility,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(targets, [null]);
    expect(find.text('You’re up to date for this compatibility version.'), findsOneWidget);
    expect(find.text('Update to version 0.4.0'), findsNothing);
  });

  testWidgets('missing or malformed server contracts cannot trigger a compatibility jump', (tester) async {
    var checks = 0;
    for (final contract in [null, '0.4.0', 'https://untrusted.example/update']) {
      final auth = connection(contract: contract);
      await tester.pumpWidget(
        page(auth, (_, _, {requiredCompatibility}) async {
          checks++;
          return null;
        }),
      );
      await rejectLogin(auth);
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
      expect(dialogUpdate, findsNothing);
      expect(find.textContaining('did not report a valid required version'), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
    expect(checks, 0);
  });
}
