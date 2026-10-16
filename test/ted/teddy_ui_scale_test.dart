import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/platform/player_linux.dart';
import 'package:plezy/mpv/video.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/teddy_settings_screen.dart';
import 'package:plezy/ted/teddy_ui_scale.dart';
import 'package:plezy/theme/mono_theme.dart';
import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });

  testWidgets('scale selection relayouts the open route and retains navigation and pointer hit tests', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: monoTheme(dark: true),
        builder: (_, child) => TeddyUiScale(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => TeddySettingsScreen(onLayoutRestart: () {}))),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.byType(TeddySettingsScreen)));
    await tester.ensureVisible(find.text('UI scale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UI scale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('75%'));
    await tester.pumpAndSettle();
    expect(SettingsService.instance.read(SettingsService.teddyUiScalePercent), 75);
    final context = tester.element(find.byType(TeddySettingsScreen));
    expect(ModalRoute.of(context), same(route));
    expect(navigator.currentState!.canPop(), true);
    expect(MediaQuery.sizeOf(context).width, closeTo(1280 / .75, .01));
    expect(MediaQuery.devicePixelRatioOf(context), 1);
    expect(tester.getRect(find.byType(TeddySettingsScreen)), const Rect.fromLTWH(0, 0, 1280, 720));
    // A second pointer selection uses the transformed coordinates and restores
    // the default without reconstructing the navigator/profile tree.
    await tester.ensureVisible(find.text('UI scale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UI scale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('100% (default)').last);
    await tester.pumpAndSettle();
    expect(SettingsService.instance.read(SettingsService.teddyUiScalePercent), 100);
    expect(ModalRoute.of(tester.element(find.byType(TeddySettingsScreen))), same(route));
    expect(tester.takeException(), isNull);
  });

  testWidgets('scaled UI preserves full-resolution native video bounds and safe-area geometry', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <MethodCall>[];
    final player = PlayerLinux();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        calls.add(call);
        return call.method == 'initialize' ? true : null;
      },
      testBody: () async {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(top: 20)),
              child: TeddyUiScale(child: child!),
            ),
            home: Video(player: player),
          ),
        );
        for (final percent in [100, 75, 50, 150]) {
          await SettingsService.instance.write(SettingsService.teddyUiScalePercent, percent);
          await tester.pumpAndSettle();
          final bounds = calls.lastWhere((c) => c.method == 'setVideoRect').arguments as Map;
          expect(bounds, containsPair('left', 0));
          expect(bounds, containsPair('top', 0));
          expect(bounds, containsPair('right', 1920));
          expect(bounds, containsPair('bottom', 1080));
          expect(bounds, containsPair('devicePixelRatio', 2.0));
          final context = tester.element(find.byType(Video));
          expect(MediaQuery.paddingOf(context).top * percent / 100, closeTo(20, .01));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => player.dispose());
      },
    );
  });
}
