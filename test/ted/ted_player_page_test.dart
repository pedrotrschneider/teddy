import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_episode_navigation.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_player_page.dart';
import 'package:plezy/ted/ted_player_screen.dart';
import 'package:plezy/ted/ted_preparing_player.dart';
import 'package:plezy/ted/ted_presentation.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/subtitle_fonts.dart';
import 'ted_playback_test.dart' show ControlFixture, sessionId, mediaPath;

const nextMedia = TedMediaIdentity('episode', 'tt1234567:1:2');
const target = TedTitle(nextMedia, 'Next episode', '', false, 0, 0, false);
const session = TedPlaybackSession(sessionId, nextMedia, mediaPath, 100000, 0, originalLanguage: 'en');

class RouteEvents extends NavigatorObserver {
  int pushes = 0, pops = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => pops++;
}

class Episode extends StatefulWidget {
  final String name;
  final VoidCallback retired;
  const Episode(this.name, this.retired, {super.key});
  @override
  State<Episode> createState() => _EpisodeState();
}

class _EpisodeState extends State<Episode> {
  @override
  Widget build(BuildContext context) => Scaffold(body: Text(widget.name));
  @override
  void dispose() {
    widget.retired();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(prepareSubtitleFonts);
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await initializeDateFormatting('en');
    LocaleSettings.setLocaleSync(AppLocale.en);
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    addTearDown(() => PlatformDetector.debugSetIsDesktopOSOverride(null));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['window_manager', 'com.plezy/macos_window', 'com.plezy/window_utils']) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
  });

  testWidgets('prepared handoff keeps one opaque route and Back reveals the current target', (tester) async {
    final navigator = GlobalKey<NavigatorState>(), observer = RouteEvents();
    final details = ValueNotifier('first details');
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        theme: monoTheme(dark: true),
        home: ValueListenableBuilder<String>(
          valueListenable: details,
          builder: (_, title, _) => Scaffold(body: Text(title)),
        ),
      ),
    );
    final page = TedPlayerPageController(navigator.currentState!);
    late TedPlayerPageEpisode first, second;
    var retired = 0;
    final firstResult = page.show(
      isPrepared: (_) => true,
      builder: (_, episode) {
        first = episode;
        return Episode('first player', () => retired++);
      },
    );
    await tester.pumpAndSettle();
    expect(observer.pushes, 2); // Home and the single player page.
    details.value = 'next details';
    first.exit(const TedPlayerExit(TedPlayerAction.next, target: target));
    expect((await firstResult)?.target, target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(retired, 1);
    expect(find.text('next details'), findsNothing);
    expect(observer.pops, 0);
    final secondResult = page.show(
      isPrepared: (_) => true,
      builder: (_, episode) {
        second = episode;
        return Episode('second player', () => retired++);
      },
    );
    await tester.pump();
    expect(find.text('second player'), findsOneWidget);
    expect(find.text('next details'), findsNothing);
    expect(observer.pushes, 2);
    first.fail();
    first.exit(const TedPlayerExit(TedPlayerAction.back));
    await tester.pump();
    expect(find.text('second player'), findsOneWidget, reason: 'Outgoing callbacks are fenced');
    second.exit(const TedPlayerExit(TedPlayerAction.back));
    expect((await secondResult)?.action, TedPlayerAction.back);
    await tester.pump(const Duration(milliseconds: 100));
    expect(retired, 1, reason: 'Ordinary Back retains its normal animation');
    await tester.pumpAndSettle();
    expect(retired, 2);
    expect(find.text('next details'), findsOneWidget);
    expect(observer.pops, 1);
    page.dispose();
    await tester.pumpWidget(const SizedBox());
    details.dispose();
  });

  testWidgets('failed preparation and cancellation return to details and fence late preparation', (tester) async {
    final f = ControlFixture();
    for (final fail in [true, false]) {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('next details')),
        ),
      );
      final page = TedPlayerPageController(navigator.currentState!);
      final pending = Completer<TedPlaybackSession>();
      var opened = 0;
      final result = page.show(
        isPrepared: (_) => false,
        builder: (_, episode) => TedPreparingPlayer(
          session: pending.future,
          metadata: TedPresentation(TedClient(f.auth)).item(target),
          onFailure: episode.fail,
          player: (_) {
            opened++;
            return const Text('unexpected player');
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      if (fail) {
        pending.completeError(const TedFailure('source_selection_required'));
        await tester.pump();
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(find.text('next details'), findsOneWidget);
      expect(page.cancelled, true);
      if (!fail) {
        pending.complete(session);
        await tester.pump();
      }
      expect(opened, 0);
      page.dispose();
      await tester.pumpWidget(const SizedBox());
    }
    f.auth.close();
  });

  testWidgets('a successor native failure returns to details while sync warnings keep playing', (tester) async {
    final f = ControlFixture();
    final navigator = GlobalKey<NavigatorState>();
    bool? retained;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        await f.auth.login('https://ted.example', 'fixture', '', 'Continuation fixture');
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: monoTheme(dark: true),
            home: const Scaffold(body: Text('next details')),
          ),
        );
        final page = TedPlayerPageController(navigator.currentState!);
        final result = page.show(
          isPrepared: (_) => false,
          builder: (_, episode) => TeddyPlayer(
            client: TedClient(f.auth),
            session: session,
            title: 'Next episode',
            player: f.player,
            onExit: episode.exit,
            onPlaybackFailure: episode.fail,
            releasePlayer: (player, retain) async {
              retained = retain;
              await player.stop();
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        f.rejectReports = true;
        f.player.handlePlayerEvent('start-file', null);
        f.player.handlePlayerEvent('file-loaded', null);
        f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 0.0});
        await settlePlayer(tester);
        expect(find.byType(TeddyPlayer), findsOneWidget);
        expect(find.text('next details'), findsNothing);
        expect(f.reports, isNotEmpty, reason: 'The sync failure must actually have occurred');
        f.rejectReports = false;
        f.player.handlePlayerEvent('end-file', {'reason': 'error', 'message': 'HTTP error 409'});
        await settlePlayer(tester);
        expect(await result, isNull);
        expect(find.byType(TeddyPlayer), findsNothing);
        expect(find.text('next details'), findsOneWidget);
        expect(retained, true);
        expect(f.reports.every((r) => r['kind'] != 'complete' && r['natural_eof'] == false), true);
        page.dispose();
        await tester.pumpWidget(const SizedBox());
        await settlePlayer(tester);
        await tester.runAsync(() => f.player.dispose());
        f.auth.close();
      },
    );
  });
}
