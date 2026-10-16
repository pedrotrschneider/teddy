import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/focus/key_event_utils.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/screens/settings/licenses_screen.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_movie_detail.dart';
import 'package:plezy/ted/ted_person_detail.dart';
import 'package:plezy/ted/ted_series_detail.dart';
import 'package:plezy/ted/teddy_settings_screen.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import '../test_helpers/prefs.dart';
import 'ted_person_detail_test.dart' show PersonFixture;
import 'ted_series_detail_test.dart' show SeriesDetailFixture;
import 'ted_keyboard_navigation_test.dart' show focused;

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    await SettingsService.getInstance();
    await SettingsService.instance.write(SettingsService.alwaysKeepSidebarOpen, true);
    addTearDown(() {
      TvDetectionService.debugReset();
      PlatformDetector.debugSetIsDesktopOSOverride(null);
    });
  });

  Future<void> mount(WidgetTester tester, TedClient client, {bool tv = true, double width = 1292}) async {
    (await TvDetectionService.getInstance()).setForceTv(tv);
    tester.view.physicalSize = Size(width, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.auth.close);
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: monoTheme(dark: true),
          navigatorObservers: [BackKeySuppressorObserver()],
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: Scaffold(
            body: TedBrowseScreen(client: client, onPlay: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder destination(String name) => find.byWidgetPredicate(
    (widget) => widget is NavigationRailItem && widget.label is Text && (widget.label as Text).data == name,
  );
  final back = find.byKey(const ValueKey('ted-detail-back'));
  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    // Apply the scroll offset before hit testing the tap. Lazy settings rows
    // can exist in the cache extent while still being below the viewport.
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> fixedAfterScroll(WidgetTester tester, Type page) async {
    expect(back, findsOneWidget);
    final position = tester.getTopLeft(back);
    expect(position.dx, 228); // Expanded rail + fixed content inset.
    expect(position.dy, 0);
    final scroll = find.descendant(of: find.byType(page), matching: find.byType(SingleChildScrollView)).first;
    await tester.drag(scroll, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(back), position);
  }

  testWidgets('show, season and episode share a fixed Back button and preserve their parent flow', (tester) async {
    await mount(tester, SeriesDetailFixture());
    await tap(tester, destination('Shows'));
    await tap(tester, find.byType(MediaCard).first);
    await fixedAfterScroll(tester, TedSeriesDetail);
    await tap(tester, find.byType(MediaCard).first);
    await fixedAfterScroll(tester, TedSeasonDetail);
    await tap(tester, find.byType(MediaCard).first);
    await fixedAfterScroll(tester, TedEpisodeDetail);
    await tap(tester, back);
    expect(find.byType(TedSeasonDetail), findsOneWidget);
    await tap(tester, back);
    expect(find.byType(TedSeriesDetail), findsOneWidget);
    await tap(tester, back);
    expect(find.byType(TedSeriesDetail), findsNothing);
    expect(back, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android system Back follows episode, season, show and closes dialogs first', (tester) async {
    await mount(tester, SeriesDetailFixture());
    await tap(tester, destination('Shows'));
    await tap(tester, find.byType(MediaCard).first);
    await tap(tester, find.byType(MediaCard).first);
    await tap(tester, find.byType(MediaCard).first);
    expect(find.byType(TedEpisodeDetail), findsOneWidget);
    final context = tester.element(find.byType(TedEpisodeDetail));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(title: Text('Back fixture')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TedEpisodeDetail), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TedSeasonDetail), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TedSeriesDetail), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TedSeriesDetail), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(destination('Shows'), findsOneWidget);
  });

  testWidgets('movie and person Back stay fixed; Up reaches Back and sidebar Right restores it', (tester) async {
    await mount(tester, PersonFixture());
    await tap(tester, destination('Movies'));
    await tap(tester, find.byType(MediaCard).first);
    await fixedAfterScroll(tester, TedMovieDetail);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(back), true);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused(destination('Movies')), true);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(back), true);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(back), false);
    await tap(tester, find.text('Actor'));
    await fixedAfterScroll(tester, TedPersonDetail);
    expect(find.text('Back'), findsNothing, reason: 'No duplicate scrolling Back in the biography');
    await tap(tester, back);
    expect(find.byType(TedMovieDetail), findsOneWidget);
    await tap(tester, back);
    expect(find.byType(TedMovieDetail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixed media Back follows the collapsed rail in both desktop and TV layouts', (tester) async {
    for (final tv in [false, true]) {
      await SettingsService.instance.write(SettingsService.alwaysKeepSidebarOpen, false);
      await mount(tester, PersonFixture(), tv: tv);
      await tap(tester, destination('Movies'));
      await tap(tester, find.byType(MediaCard).first);
      expect(tester.getTopLeft(back), const Offset(88, 0));
      expect(tester.getSize(destination('Movies')).width, lessThan(100));
      await tap(tester, back);
      expect(find.byType(TedMovieDetail), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('compact media Back stays fixed and clears Mac window controls without a rail', (tester) async {
    await mount(tester, PersonFixture(), tv: false, width: 640);
    await tap(tester, find.text('Movies'));
    await tap(tester, find.byType(MediaCard).first);
    expect(find.byType(NavigationBar), findsOneWidget);
    final position = tester.getTopLeft(back);
    expect(position, Offset(Platform.isMacOS ? 88 : 8, 0));
    await tester.drag(
      find.descendant(of: find.byType(TedMovieDetail), matching: find.byType(SingleChildScrollView)).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(back), position);
    await tap(tester, back);
    expect(find.byType(TedMovieDetail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings retains sidebar, modal precedence and caller; a destination replaces it', (tester) async {
    await mount(tester, PersonFixture());
    await tap(tester, destination('Movies'));
    await tap(tester, find.byType(MediaCard).first);
    await tap(tester, find.byTooltip('Settings'));
    expect(find.byType(TeddySettingsScreen), findsOneWidget);
    expect(destination('Movies'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(TeddySettingsScreen)).dx, 220);
    expect(tester.widget<NavigationRailItem>(destination('Settings')).isSelected, true);
    await tap(tester, find.text('Startup Section'));
    expect(find.byType(AlertDialog), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TeddySettingsScreen), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TeddySettingsScreen), findsNothing);
    expect(find.byType(TedMovieDetail), findsOneWidget);
    await tap(tester, find.byTooltip('Settings'));
    await tap(tester, destination('Shows'));
    expect(find.byType(TeddySettingsScreen), findsNothing);
    expect(find.byType(TedMovieDetail), findsNothing);
    expect(tester.widget<NavigationRailItem>(destination('Shows')).isSelected, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('license pages retain the settings sidebar and Escape returns one page at a time', (tester) async {
    LicenseRegistry.addLicense(
      () => Stream.value(const LicenseEntryWithLineBreaks(['shell-navigation-fixture'], 'Test license')),
    );
    await mount(tester, PersonFixture(), tv: false);
    await tap(tester, find.byTooltip('Settings'));
    await tester.scrollUntilVisible(
      find.text('Open source licenses'),
      500,
      scrollable: find.descendant(of: find.byType(TeddySettingsScreen), matching: find.byType(Scrollable)).first,
    );
    await tap(tester, find.text('Open source licenses'));
    expect(find.byType(LicensesScreen), findsOneWidget);
    expect(destination('Home'), findsOneWidget);
    await tap(tester, find.text('shell-navigation-fixture'));
    expect(find.byType(LicenseDetailScreen), findsOneWidget);
    expect(destination('Home'), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(LicensesScreen), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TeddySettingsScreen), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TeddySettingsScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
