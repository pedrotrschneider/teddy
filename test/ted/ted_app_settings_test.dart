import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_app_settings.dart';
import 'package:plezy/ted/teddy_settings_actions.dart';
import 'package:plezy/services/settings_export_service.dart';
import 'package:plezy/models/teddy_section.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import '../test_helpers/prefs.dart';

final class ControlledPreferences extends InMemorySharedPreferencesAsync {
  ControlledPreferences() : super.withData({SettingsService.forceTvMode.key: false});
  Completer<void>? held;
  bool refuse = false;
  @override
  Future<bool> setBool(String key, bool value, SharedPreferencesOptions options) async {
    if (key == SettingsService.forceTvMode.key) {
      await held?.future;
      if (refuse) throw StateError('Preference write refused');
    }
    return super.setBool(key, value, options);
  }

  Future<Object?> savedMode() async => (await getPreferences(
    GetPreferencesParameters(filter: PreferencesFilters(allowList: {SettingsService.forceTvMode.key})),
    const SharedPreferencesOptions(),
  ))[SettingsService.forceTvMode.key];
}

void main() {
  late ControlledPreferences store;
  setUp(() async {
    resetSharedPreferencesForTest();
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    addTearDown(() {
      TvDetectionService.debugReset();
      PlatformDetector.debugSetIsDesktopOSOverride(null);
    });
    store = ControlledPreferences();
    SharedPreferencesAsyncPlatform.instance = store;
    await SettingsService.getInstance();
    await TvDetectionService.getInstance();
  });

  Future<void> mount(WidgetTester tester, VoidCallback restarted) async {
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  child: const Text('Open settings'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => TeddySettingsScreen(
                        onLayoutRestart: () {
                          restarted();
                          Navigator.of(context).popUntil((route) => route.isFirst);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
  }

  final toggle = find.descendant(
    of: find.byKey(const ValueKey('teddy-force-tv')),
    matching: find.byType(FocusableSwitchListTile),
  );

  testWidgets('Escape closes the active setting dialog, then the page, including lost focus', (tester) async {
    await mount(tester, () {});
    await tester.tap(find.text('Startup Section'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TeddySettingsScreen), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TeddySettingsScreen), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
  });

  test(
    'reset includes patterns and fullscreen; portable round-trip retains native options and excludes secrets',
    () async {
      final settings = SettingsService.instance;
      expect(settings.read(SettingsService.teddyAutoPlayNextEpisode), false);
      expect(settings.read(SettingsService.teddyStartupSection), TeddySection.home);
      expect(settings.read(SettingsService.teddyDownloadChunkMiB), 512);
      expect(settings.read(SettingsService.teddyMaxSimultaneousDownloads), 1);
      expect(settings.read(SettingsService.teddyUiScalePercent), 100);
      expect(settings.read(SettingsService.posterIndicatorScalePercent), 200);
      await settings.write(SettingsService.teddyStartupSection, TeddySection.downloads);
      await settings.write(SettingsService.teddyAutoPlayNextEpisode, true);
      await settings.write(SettingsService.teddyDownloadChunkMiB, 1024);
      await settings.write(SettingsService.teddyMaxSimultaneousDownloads, 3);
      await settings.write(SettingsService.teddyUiScalePercent, 75);
      await settings.write(SettingsService.posterIndicatorScalePercent, 150);
      await settings.write(SettingsService.useExoPlayer, true);
      await settings.write(SettingsService.introPattern, 'custom-opening');
      await settings.write(SettingsService.startInFullscreen, true);
      await settings.prefs.setString('private_fixture_token', 'preserve');
      await settings.write(SettingsService.customDownloadPath, '/private/device-only');
      final exported = SettingsExportService.buildExportMap(settings.prefs, currentUserUuid: 'teddy');
      expect((exported['prefs'] as Map).containsKey('private_fixture_token'), false);
      expect((exported['prefs'] as Map).containsKey(SettingsService.customDownloadPath.key), false);
      await resetTeddySettings(settings);
      expect(settings.read(SettingsService.introPattern), SettingsService.defaultIntroPattern);
      expect(settings.read(SettingsService.startInFullscreen), false);
      expect(settings.read(SettingsService.teddyDownloadChunkMiB), 512);
      expect(settings.read(SettingsService.teddyMaxSimultaneousDownloads), 1);
      expect(settings.read(SettingsService.teddyUiScalePercent), 100);
      expect(settings.read(SettingsService.posterIndicatorScalePercent), 200);
      expect(settings.read(SettingsService.useExoPlayer), false);
      expect(settings.prefs.getString('private_fixture_token'), 'preserve');
      await SettingsExportService.applyImportMap(exported, settings.prefs, currentUserUuid: 'teddy');
      settings.refreshListenables();
      expect(settings.read(SettingsService.teddyStartupSection), TeddySection.downloads);
      expect(settings.read(SettingsService.teddyAutoPlayNextEpisode), true);
      expect(settings.read(SettingsService.teddyDownloadChunkMiB), 1024);
      expect(settings.read(SettingsService.teddyMaxSimultaneousDownloads), 3);
      expect(settings.read(SettingsService.teddyUiScalePercent), 75);
      expect(settings.read(SettingsService.posterIndicatorScalePercent), 150);
      expect(settings.read(SettingsService.useExoPlayer), true);
      expect(settings.read(SettingsService.introPattern), 'custom-opening');
    },
  );

  testWidgets('TV mode waits for persistence, returns home and can be turned off', (tester) async {
    var restarts = 0;
    await mount(tester, () => restarts++);
    store.held = Completer<void>();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(restarts, 0);
    expect(PlatformDetector.isTV(), isFalse);
    expect(tester.widget<FocusableSwitchListTile>(toggle).onChanged, isNull);
    expect(await store.savedMode(), isFalse);
    store.held!.complete();
    await tester.pumpAndSettle();
    expect(restarts, 1);
    expect(PlatformDetector.isTV(), isTrue);
    expect(await store.savedMode(), isTrue);
    expect(find.byType(TeddySettingsScreen), findsNothing);

    // The saved override is the same input used during real app startup.
    TvDetectionService.debugReset();
    await TvDetectionService.getInstance(forceTv: SettingsService.instance.read(SettingsService.forceTvMode));
    expect(PlatformDetector.isTV(), isTrue);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(tester.widget<FocusableSwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(restarts, 2);
    expect(PlatformDetector.isTV(), isFalse);
    expect(await store.savedMode(), isFalse);
    expect(find.byType(TeddySettingsScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android exposes the bundled video backend selection and saves the choice', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await mount(tester, () {});
      await tester.scrollUntilVisible(find.text('Android video player'), 250, scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Android video player'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ExoPlayer'));
      await tester.pumpAndSettle();
      expect(SettingsService.instance.read(SettingsService.useExoPlayer), true);
      expect(find.text('ExoPlayer. Applies to the next video.'), findsOneWidget);
      expect(find.textContaining('MPV only; ExoPlayer selects decoders automatically.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a failed save keeps the current layout, reports failure and allows retry', (tester) async {
    var restarts = 0;
    await mount(tester, () => restarts++);
    store.refuse = true;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(restarts, 0);
    expect(PlatformDetector.isTV(), isFalse);
    expect(await store.savedMode(), isFalse);
    expect(tester.widget<FocusableSwitchListTile>(toggle).value, isFalse);
    expect(find.text('Could not save TV mode. Please try again.'), findsOneWidget);
    store.refuse = false;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(restarts, 1);
    expect(PlatformDetector.isTV(), isTrue);
    expect(await store.savedMode(), isTrue);
    expect(tester.takeException(), isNull);
  });
}
