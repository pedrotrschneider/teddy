import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/mpv/video.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_player_screen.dart';
import 'package:plezy/ted/ted_player_loading.dart';
import 'package:plezy/focus/transport_keys.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_episode_navigation.dart';
import 'package:plezy/ted/ted_app_shutdown.dart';
import 'package:plezy/ted/ted_focus_recovery.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/video_controls/widgets/video_controls_header.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/widgets/video_controls/video_control_button.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/timeline_slider.dart';
import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';
import 'ted_playback_test.dart' show ControlFixture, sessionId, mediaPath;

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await initializeDateFormatting('en');
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    addTearDown(() => PlatformDetector.debugSetIsDesktopOSOverride(null));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['window_manager', 'com.plezy/macos_window', 'com.plezy/window_utils']) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    LocaleSettings.setLocaleSync(AppLocale.en);
  });
  testWidgets('the full controls leave the native video visible after its first frame', (tester) async {
    final f = ControlFixture();
    final boundary = GlobalKey();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        await f.auth.login('https://ted.example', 'fixture', '', 'Video composition fixture');
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: monoTheme(dark: true),
              home: TeddyPlayer(
                client: TedClient(f.auth),
                player: f.player,
                title: 'Fixture video',
                session: const TedPlaybackSession(
                  sessionId,
                  TedMediaIdentity('movie', 'tt1234567'),
                  mediaPath,
                  100000,
                  0,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        Future<int?> alpha(Offset point) => tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          final value = bytes!.getUint8((point.dy.floor() * image.width + point.dx.floor()) * 4 + 3);
          image.dispose();
          return value;
        });

        final viewport = tester.getCenter(find.byType(Video)) + const Offset(140, 0);
        expect(await alpha(viewport), 255);
        f.player.handlePlayerEvent('start-file', null);
        f.player.handlePlayerEvent('file-loaded', null);
        f.player.handlePlayerEvent('playback-restart', null);
        await tester.pumpAndSettle();
        expect(await alpha(viewport), 0, reason: 'Flutter must leave the native video plane visible');
        expect(await alpha(tester.getTopLeft(find.byType(VideoControlsHeader)) + const Offset(22, 22)), greaterThan(0));
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await f.player.dispose();
        });
        f.auth.close();
      },
    );
  });

  TedPlayerExit? lastExit;
  Future<void> mount(
    WidgetTester tester,
    ControlFixture f, {
    TedEpisodeTargets? targets,
    Future<void> Function(TedTitle)? onTransition,
    void Function(TedTitle)? onPrefetch,
  }) async {
    await f.auth.login('https://ted.example', 'fixture', '', 'Full controls fixture');
    final routes = TedFocusRoutes();
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        navigatorObservers: [routes],
        builder: (_, child) => TedFocusRecovery(routes: routes, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context)
                  .push<TedPlayerExit>(
                    MaterialPageRoute(
                      builder: (_) => TeddyPlayer(
                        client: TedClient(f.auth),
                        player: f.player,
                        title: 'Fixture video',
                        episodeTargets: targets == null ? null : Future.value(targets),
                        onEpisodeTransition: onTransition,
                        onPrefetchNext: onPrefetch,
                        session: TedPlaybackSession(
                          sessionId,
                          targets == null
                              ? const TedMediaIdentity('movie', 'tt1234567')
                              : const TedMediaIdentity('episode', 'tt1234567:1:2'),
                          mediaPath,
                          100000,
                          0,
                          source: onPrefetch == null ? 'mapped_rd' : 'addon',
                          addonId: onPrefetch == null ? '' : 'a' * 64,
                          bingeKey: onPrefetch == null ? '' : 'b' * 64,
                        ),
                      ),
                    ),
                  )
                  .then((value) => lastExit = value),
              child: const Text('Start fixture'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start fixture'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    f.player.handlePlayerEvent('start-file', null);
    f.player.handlePlayerEvent('file-loaded', null);
    f.player.handlePropertyChange('track-list', [
      {'type': 'audio', 'id': 1, 'lang': 'eng', 'selected': true},
      {'type': 'audio', 'id': 2, 'lang': 'por', 'title': 'Portuguese audio'},
      {'type': 'sub', 'id': 3, 'lang': 'eng', 'title': 'English captions'},
      {'type': 'sub', 'id': 4, 'lang': 'spa', 'title': 'Spanish captions'},
    ]);
    f.player.handlePropertyChange('pause', false);
    f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 0.0});
    await tester.pump();
    f.player.handlePropertyChange('time-pos', 17.0);
    f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
    await tester.pumpAndSettle();
  }

  Future<void> playerTest(WidgetTester tester, ControlFixture f, Future<void> Function() body) =>
      withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        methodHandler: f.method,
        testBody: () async {
          try {
            await body();
          } finally {
            if (f.releaseRefresh != null && !f.releaseRefresh!.isCompleted) f.releaseRefresh!.complete();
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            await tester.runAsync(() => f.player.dispose());
            f.auth.close();
          }
        },
      );

  for (final autoplay in [false, true]) {
    testWidgets(
      'natural completion ${autoplay ? 'advances' : 'returns to the current episode'} according to Settings',
      (tester) async {
        await (await SettingsService.getInstance()).write(SettingsService.teddyAutoPlayNextEpisode, autoplay);
        final f = ControlFixture();
        await playerTest(tester, f, () async {
          final next = TedTitle(const TedMediaIdentity('episode', 'tt1234567:1:3'), 'Next', '', false, 0, 0, false);
          await mount(tester, f, targets: TedEpisodeTargets(next: next));
          f.player.handlePropertyChange('duration', 100.0);
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 99.5});
          f.player.handlePropertyChange('time-pos', 99.5);
          f.nativeEof = true;
          f.player.handlePropertyChange('eof-reached', true);
          await tester.pumpAndSettle();
          expect(find.byType(TeddyPlayer), findsNothing);
          expect(lastExit!.target?.media, autoplay ? next.media : null);
          expect(f.reports.last['natural_eof'], true);
        });
      },
    );
  }

  testWidgets('the exit lifecycle stops the scoped player at its offset before storage closes', (tester) async {
    final f = ControlFixture();
    List<Map> saved = [];
    var disposedBeforeStorage = false;
    final shutdown =
        TedAppShutdown(
            closeStorage: () async {
              disposedBeforeStorage = f.calls.any((call) => call.method == 'dispose');
              saved = f.reports;
            },
          )
          ..stopServices = () async {
            f.auth.close();
          };
    final listener = AppLifecycleListener(onExitRequested: shutdown.requestExit);
    addTearDown(listener.dispose);
    await playerTest(tester, f, () async {
      await f.auth.login('https://ted.example', 'fixture', '', 'Quit fixture');
      await tester.pumpWidget(
        TedAppShutdownScope(
          shutdown: shutdown,
          child: MaterialApp(
            theme: monoTheme(dark: true),
            home: TeddyPlayer(
              client: TedClient(f.auth),
              player: f.player,
              title: 'Quit fixture',
              session: const TedPlaybackSession(
                sessionId,
                TedMediaIdentity('movie', 'tt1234567'),
                mediaPath,
                100000,
                0,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      f.player.handlePlayerEvent('start-file', null);
      f.player.handlePlayerEvent('file-loaded', null);
      f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 0.0});
      await tester.pump();
      f.player.handlePropertyChange('time-pos', 17.0);
      f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
      await tester.pumpAndSettle();
      ui.AppExitResponse? response;
      final exit = tester.binding.handleRequestAppExit().then((value) => response = value);
      // Native stream cancellation can finish on the real event loop while
      // widget callbacks use the simulated clock. Drive both without extending
      // the production deadline or unmounting the player to release teardown.
      for (var i = 0; i < 20 && response == null; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(response, ui.AppExitResponse.exit);
      await exit;
      expect(disposedBeforeStorage, true);
      expect(saved.map((report) => report['kind']), ['start', 'stop']);
      expect(saved.last['position_ms'], 17000);
      expect(saved.last['natural_eof'], false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
  for (final audio in [true, false]) {
    testWidgets(
      'the actual ${audio ? 'audio' : 'subtitle'} picker changes native tracks without reopening after token expiry',
      (tester) async {
        final f = ControlFixture();
        await playerTest(tester, f, () async {
          await mount(tester, f);
          await tester.tap(find.byTooltip(t.videoControls.tracksButton));
          await tester.pumpAndSettle();
          f.now = f.now.add(const Duration(minutes: 11));
          f.releaseRefresh = Completer();
          f.calls.clear();
          await tester.tap(find.textContaining(audio ? 'Portuguese audio' : 'Spanish captions'));
          await tester.pumpAndSettle();
          expect(f.refreshEntered.isCompleted, false);
          expect(f.rotations, 0);
          expect(
            f.calls.where((call) => call.method == 'command' && (call.arguments as Map)['args'][0] == 'loadfile'),
            isEmpty,
          );
          final property = audio ? 'aid' : 'sid';
          Iterable selections() =>
              f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == property);
          expect(selections().length, 1);
          expect((selections().single.arguments as Map)['value'], audio ? '2' : '4');
          // The eventual stop report still needs a current API bearer; only
          // decoder controls must avoid rotating/reopening the media.
          f.releaseRefresh!.complete();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('Start fixture'), findsOneWidget);
        });
      },
    );
  }
  testWidgets('TV auxiliary controls fit a narrow window and stay aligned with transport', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(TvDetectionService.debugReset);
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = ControlFixture();
    await playerTest(tester, f, () async {
      await mount(tester, f);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final play = find.byWidgetPredicate(
        (w) => w is VideoControlButton && w.semanticLabel == t.videoControls.pauseButton,
      );
      final full = find.byWidgetPredicate(
        (w) => w is VideoControlButton && w.semanticLabel == t.videoControls.fullscreenButton,
      );
      expect(tester.getCenter(play).dx, closeTo(320, 1));
      expect(tester.getCenter(full).dy, closeTo(tester.getCenter(play).dy, 1));
      expect(tester.getRect(full).right, lessThanOrEqualTo(640));
    });
  });

  testWidgets('TV transport is larger and centered; held timeline seeks keep focus and Down selects Pause', (
    tester,
  ) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(TvDetectionService.debugReset);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = ControlFixture();
    await playerTest(tester, f, () async {
      final next = TedTitle(const TedMediaIdentity('episode', 'tt1234567:1:3'), 'Next', '', false, 0, 0, false);
      await mount(tester, f, targets: TedEpisodeTargets(next: next));
      final play = find.byWidgetPredicate(
        (w) => w is VideoControlButton && w.semanticLabel == t.videoControls.pauseButton,
      );
      final button = tester.widget<VideoControlButton>(play);
      expect(tester.getSize(play).width, greaterThanOrEqualTo(60));
      final icon = tester.widget<IconButton>(find.descendant(of: play, matching: find.byType(IconButton)));
      expect(icon.iconSize, 48);
      expect(tester.getCenter(play).dx, closeTo(640, 1));
      for (final label in [
        t.videoControls.settingsButton,
        t.videoControls.tracksButton,
        t.videoControls.fullscreenButton,
      ]) {
        final control = find.byWidgetPredicate((w) => w is VideoControlButton && w.semanticLabel == label);
        expect(tester.getCenter(control).dy, closeTo(tester.getCenter(play).dy, 1));
      }
      expect(find.byTooltip(t.videoControls.aspectRatioButton), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is VideoControlButton && w.semanticLabel == t.videoControls.nextChapterButton),
        findsNothing,
      );
      final slider = tester.widget<TimelineSlider>(find.byType(TimelineSlider));
      slider.focusNode!.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 300));
      expect(slider.focusNode!.hasPrimaryFocus, true);
      expect(find.byType(TedPlayerLoading), findsOneWidget);
      final lastSeek = f.calls.lastWhere((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'seek');
      final target = double.parse((lastSeek.arguments as Map)['args'][1] as String);
      f.player.handlePlayerEvent('playback-restart', {'positionSeconds': target});
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(button.focusNode!.hasPrimaryFocus, true);
      await tester.tap(
        find.byWidgetPredicate((w) => w is VideoControlButton && w.semanticLabel == t.videoControls.nextButton),
      );
      await tester.pumpAndSettle();
      expect(lastExit!.action, TedPlayerAction.next);
      expect(lastExit!.target!.media, next.media);
      expect(f.reports.last['kind'], 'complete');
      expect(f.reports.last['position_ms'], lessThan(90000));
    });
  });

  testWidgets('buffering pulses the title without taking focus, and stops after decoding resumes', (tester) async {
    await SettingsService.getInstance();
    (await TvDetectionService.getInstance()).setForceTv(true);
    addTearDown(() => TvDetectionService.debugReset());
    final f = ControlFixture();
    await playerTest(tester, f, () async {
      await mount(tester, f);
      final slider = tester.widget<TimelineSlider>(find.byType(TimelineSlider));
      slider.focusNode!.requestFocus();
      await tester.pump();
      f.player.handlePropertyChange('paused-for-cache', true);
      await tester.pump();
      expect(find.byType(TedPlayerLoading), findsOneWidget);
      final fade = find.descendant(of: find.byType(TedPlayerLoading), matching: find.byType(FadeTransition));
      final scale = find.descendant(of: find.byType(TedPlayerLoading), matching: find.byType(ScaleTransition));
      final first = tester.widget<FadeTransition>(fade).opacity.value;
      await tester.pump(const Duration(milliseconds: 550));
      expect(tester.widget<FadeTransition>(fade).opacity.value, greaterThan(first));
      expect(tester.widget<FadeTransition>(fade).opacity.value, inInclusiveRange(.55, 1));
      expect(tester.widget<ScaleTransition>(scale).scale.value, inInclusiveRange(.94, 1.06));
      expect(slider.focusNode!.hasPrimaryFocus, true);
      f.player.handlePropertyChange('paused-for-cache', false);
      await tester.pumpAndSettle();
      expect(find.byType(TedPlayerLoading), findsNothing);
      expect(slider.focusNode!.hasPrimaryFocus, true);
    });
  });

  testWidgets('pending seek shows loading even without a buffering flag; paused playback does not', (tester) async {
    final f = ControlFixture();
    await playerTest(tester, f, () async {
      await mount(tester, f);
      final controls = tester.widget<PlexVideoControls>(find.byType(PlexVideoControls));
      await controls.onSeekRequested!(const Duration(seconds: 40));
      await tester.pump();
      expect(find.byType(TedPlayerLoading), findsOneWidget);
      f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 39.9});
      await tester.pumpAndSettle();
      expect(find.byType(TedPlayerLoading), findsNothing);
      await controls.onPlayPauseRequested!(TransportCommand.pause);
      await tester.pumpAndSettle();
      expect(find.byType(TedPlayerLoading), findsNothing);
    });
  });

  testWidgets('pointer reveals without changing focus; visible and hidden arrows focus the timeline and seek', (
    tester,
  ) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(() => TvDetectionService.debugReset());
    final f = ControlFixture();
    await playerTest(tester, f, () async {
      await mount(tester, f);
      final controls = tester.widget<PlexVideoControls>(find.byType(PlexVideoControls));
      controls.chromeController.hide();
      await tester.pumpAndSettle();
      final surface = FocusManager.instance.primaryFocus;
      final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(20, 200));
      await mouse.moveTo(const Offset(50, 200));
      await tester.pumpAndSettle();
      var slider = tester.widget<TimelineSlider>(find.byType(TimelineSlider));
      expect(slider.focusNode!.hasPrimaryFocus, false);
      expect(FocusManager.instance.primaryFocus, same(surface));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(slider.focusNode!.hasPrimaryFocus, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final pause = tester.widget<VideoControlButton>(
        find.byWidgetPredicate((w) => w is VideoControlButton && w.semanticLabel == t.videoControls.pauseButton),
      );
      expect(pause.focusNode!.hasPrimaryFocus, true);
      controls.chromeController.hide();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 30));
      slider = tester.widget<TimelineSlider>(find.byType(TimelineSlider));
      expect(slider.focusNode!.hasPrimaryFocus, true);
      await tester.pump(); // Render the feedback requested by the reveal frame.
      expect(find.text('+10 s'), findsOneWidget);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 250));
      final seeks = f.calls.where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'seek');
      expect((seeks.last.arguments as Map)['args'], ['seek', '27.0', 'absolute']);
      f.player.handlePropertyChange('time-pos', 27.0);
      f.player.handlePlayerEvent('playback-restart', null);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 250));
      expect((seeks.last.arguments as Map)['args'], ['seek', '17.0', 'absolute']);
      // A queued pre-seek frame and an unbuffered EOF must not navigate.
      f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 99.0});
      f.player.handlePropertyChange('eof-reached', true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(TeddyPlayer), findsOneWidget);
      expect(f.calls.where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile').length, 1);
      f.player.handlePropertyChange('eof-reached', false);
      f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 16.9});
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 250));
      expect((seeks.last.arguments as Map)['args'], ['seek', '26.9', 'absolute']);
      await mouse.removePointer();
    });
  });

  testWidgets('episode target is installed while player still covers the prior page, before source loading', (
    tester,
  ) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(TvDetectionService.debugReset);
    final f = ControlFixture();
    final installed = Completer<void>(), release = Completer<void>();
    await playerTest(tester, f, () async {
      final next = TedTitle(const TedMediaIdentity('episode', 'tt1234567:1:3'), 'Next', '', false, 0, 0, false);
      await mount(
        tester,
        f,
        targets: TedEpisodeTargets(next: next),
        onTransition: (target) async {
          expect(target.media, next.media);
          expect(find.byType(TeddyPlayer), findsOneWidget);
          installed.complete();
          await release.future;
        },
      );
      await tester.tap(
        find.byWidgetPredicate((w) => w is VideoControlButton && w.semanticLabel == t.videoControls.nextButton),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(installed.isCompleted, true);
      expect(find.byType(TeddyPlayer), findsOneWidget);
      release.complete();
      await tester.pumpAndSettle();
      expect(lastExit!.target!.media, next.media);
      expect(find.byType(TeddyPlayer), findsNothing);
    });
  });

  testWidgets('TV track menus own pointer, arrows and focus recovery; Escape closes only the menu', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(TvDetectionService.debugReset);
    final f = ControlFixture();
    await playerTest(tester, f, () async {
      await mount(tester, f);
      await tester.tap(find.byTooltip(t.videoControls.tracksButton));
      await tester.pumpAndSettle();
      final sheet = OverlaySheetController.of(tester.element(find.byType(FocusableListTile).first));
      expect(sheet.ownsFocus(FocusManager.instance.primaryFocus), true);
      FocusManager.instance.rootScope.requestFocus();
      await tester.pumpAndSettle();
      expect(sheet.ownsFocus(FocusManager.instance.primaryFocus), true);
      final audioTiles = find
          .byType(ListTile)
          .evaluate()
          .map((e) => e.widget as ListTile)
          .where((tile) => (tile.title as Text?)?.data?.contains('English') ?? false)
          .toList();
      audioTiles.first.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        f.calls
            .where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'aid')
            .map((c) => (c.arguments as Map)['value']),
        contains('2'),
      );
      expect(sheet.isOpen, false);
      await tester.tap(find.byTooltip(t.videoControls.tracksButton));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Spanish captions'));
      await tester.pumpAndSettle();
      expect(
        f.calls
            .where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'sid')
            .map((c) => (c.arguments as Map)['value']),
        contains('4'),
      );
      await tester.tap(find.byTooltip(t.videoControls.tracksButton));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(sheet.isOpen, false);
      expect(find.byType(TeddyPlayer), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TeddyPlayer), findsNothing);
    });
  });

  for (final hidden in [false, true]) {
    testWidgets('Escape exits ${hidden ? 'hidden' : 'visible'} player chrome even without child focus', (tester) async {
      final f = ControlFixture();
      await playerTest(tester, f, () async {
        await mount(tester, f);
        if (hidden) tester.widget<PlexVideoControls>(find.byType(PlexVideoControls)).chromeController.hide();
        await tester.pumpAndSettle();
        FocusManager.instance.rootScope.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(TeddyPlayer), findsNothing);
        expect(lastExit!.action, TedPlayerAction.back);
        expect(f.reports.last['natural_eof'], false);
      });
    });
  }

  testWidgets('Escape still saves the stop and exits when the failed decoder rejects Pause', (tester) async {
    final f = ControlFixture();
    await playerTest(tester, f, () async {
      await mount(tester, f);
      f.rejectPause = true;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TeddyPlayer), findsNothing);
      expect(f.reports.last['kind'], 'stop');
      expect(f.reports.last['position_ms'], 17000);
      expect(f.reports.last['natural_eof'], false);
    });
  });

  testWidgets('Back retains the player until stop is acknowledged and retry preserves the report identity', (
    tester,
  ) async {
    final f = ControlFixture();
    await playerTest(tester, f, () async {
      await mount(tester, f);
      f.rejectReports = true;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        f.reports.where((e) => e['kind'] == 'stop'),
        isNotEmpty,
        reason: 'System Back must request a stop before deciding whether navigation is allowed',
      );
      expect(find.byType(TeddyPlayer), findsOneWidget);
      expect(find.text('Retry sync'), findsOneWidget);
      f.rejectReports = false;
      await tester.tap(find.text('Retry sync'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Start fixture'), findsOneWidget);
      final stops = f.reports.where((e) => e['kind'] == 'stop');
      expect(stops.map((e) => e['id']).toSet().length, 1);
    });
  });
  testWidgets('next episode prefetch triggers once at halfway and never before', (tester) async {
    final f = ControlFixture();
    final requested = <TedTitle>[];
    const next = TedTitle(TedMediaIdentity('episode', 'tt1234567:1:3'), 'Next', '', false, 0, 0, false);
    await playerTest(tester, f, () async {
      await mount(
        tester,
        f,
        targets: const TedEpisodeTargets(next: next),
        onPrefetch: requested.add,
      );
      f.player.handlePropertyChange('time-pos', 49.0);
      f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 49.0});
      await tester.pump();
      expect(requested, isEmpty);
      f.player.handlePropertyChange('time-pos', 50.0);
      f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 50.0});
      await tester.pump();
      expect(requested, [next]);
      f.player.handlePropertyChange('time-pos', 60.0);
      f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 60.0});
      await tester.pump();
      expect(requested, [next]);
    });
  });
}
