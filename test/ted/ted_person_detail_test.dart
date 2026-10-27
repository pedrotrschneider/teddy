import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/focus/locked_hub_controller.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_movie_detail.dart';
import 'package:plezy/ted/ted_person_detail.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/cast_member_strip.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import '../test_helpers/prefs.dart';
import 'ted_movie_detail_test.dart' show MovieFixture, firstSource, secondSource;
import 'ted_metadata_client_test.dart' show metadataData;

TedFilmographyEntry credit(
  String id,
  String name, {
  bool viewed = false,
  bool watched = false,
  bool series = false,
  bool unresolved = false,
  List<Map<String, dynamic>> jointWatches = const [],
}) => TedFilmographyEntry.fromJson({
  'item': {'Id': id, 'Type': series ? 'Series' : 'Movie', 'Name': name, 'ProductionYear': 2026},
  'watchlist': false,
  'user_rating': null,
  'identity_status': unresolved ? 'missing' : 'ready',
  'roles': ['Lead'],
  'images': [],
  if (!unresolved) 'media': {'kind': series ? 'series' : 'movie', 'id': 'tt${int.parse(id[0]) + 5000000}'},
  'watched': unresolved ? null : watched,
  'viewed': unresolved ? null : viewed,
  'joint_watches': jointWatches,
});

class PersonFixture extends MovieFixture {
  int peopleReads = 0;
  final creditPages = <String?>[];
  bool failPage = false, loopPage = false, noViewed = false;
  String overview = 'A detailed biography.';
  String personStatus = 'ready';
  Completer<TedMetadataSnapshot>? heldPerson;
  Completer<TedTitle>? heldAppearance;
  List<TedFilmographyEntry>? customCredits;
  @override
  Future<TedTitle> title(TedMediaIdentity media) => heldAppearance?.future ?? super.title(media);
  PersonFixture() {
    credits = [
      {'Id': firstSource, 'Name': 'Actor', 'Type': 'Actor', 'Role': 'Bruce Wayne'},
    ];
  }
  TedMetadataSnapshot get biography => TedMetadataSnapshot.fromJson({
    ...metadataData(status: personStatus),
    'item': <String, dynamic>{
      'Id': firstSource,
      'Type': 'Person',
      'Name': 'Actor',
      'Overview': overview,
      'PremiereDate': '1974-01-30T00:00:00Z',
      'ProductionLocations': ['Wales, UK'],
    },
  });
  @override
  Future<TedMetadataSnapshot> person(String id) async {
    peopleReads++;
    return heldPerson?.future ?? biography;
  }

  @override
  Future<TedFilmographyPage> filmography(String id, {String? after}) async {
    creditPages.add(after);
    if (customCredits != null) return TedFilmographyPage(customCredits!, null);
    if (after != null && failPage) throw const TedFailure('unavailable');
    if (after != null && loopPage) return const TedFilmographyPage([], secondSource);
    return after == null
        ? TedFilmographyPage([
            credit(firstSource, 'Started movie', viewed: !noViewed),
            credit(secondSource, 'One episode show', viewed: !noViewed, series: true),
          ], secondSource)
        : TedFilmographyPage([
            credit('33333333-3333-4333-8333-333333333333', 'Other movie'),
            credit('44444444-4444-4444-8444-444444444444', 'Unidentified', unresolved: true),
          ], null);
  }

  @override
  Future<Uint8List?> personPortrait(String id) async => throw const TedFailure('unavailable');
}

Map<String, dynamic> jointViewing({bool seen = true, int watched = 0, int available = 1}) => {
  'account_id': 2,
  'name': 'Joint account',
  'color': '#12ABCD',
  'watch': {'seen': seen, 'watched': watched, 'available': available, 'progress': null},
};

void main() {
  setUpAll(() async {
    await (FontLoader('Go Noto Current')..addFont(rootBundle.load('assets/go-noto-current-regular.ttf'))).load();
  });
  setUp(() async {
    resetSharedPreferencesForTest();
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    await SettingsService.getInstance();
    addTearDown(() {
      TvDetectionService.debugReset();
      PlatformDetector.debugSetIsDesktopOSOverride(null);
    });
  });
  Future<void> mount(
    WidgetTester tester,
    PersonFixture client, {
    bool tv = false,
    bool shell = false,
    Size size = const Size(1292, 950),
  }) async {
    (await TvDetectionService.getInstance()).setForceTv(tv);
    expect(PlatformDetector.isTV(), tv);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.auth.close);
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: monoTheme(
            dark: true,
          ).copyWith(textTheme: monoTheme(dark: true).textTheme.apply(fontFamily: 'Go Noto Current')),
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: Scaffold(
            body: shell
                ? TedBrowseScreen(client: client, onPlay: (_) async {})
                : TedPersonDetail(
                    client: client,
                    person: const TedMetadataPerson(id: firstSource, name: 'Actor', type: 'Actor', role: 'Bruce Wayne'),
                    origin: client.data(const TedMediaIdentity('movie', 'tt4000000')),
                    horizontalInset: 40,
                    onClose: () {},
                    onSidebar: () {},
                    onHeader: () {},
                    onOpen: (_) {},
                  ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('person filmography matches standard media poster sizing beneath its desktop/TV banner', (tester) async {
    for (final tv in [false, true]) {
      final client = PersonFixture();
      await mount(tester, client, tv: tv);
      await tester.pumpAndSettle();
      expect(find.text('Actor'), findsOneWidget);
      expect(find.text('Wales, UK'), findsOneWidget);
      expect(find.textContaining('Born 30/1/1974'), findsOneWidget);
      final biography = tester.getRect(find.text(client.overview));
      final portrait = tester.getRect(find.byKey(const ValueKey('person-portrait')));
      final facts = tester.getRect(find.byKey(const ValueKey('person-facts')));
      expect((biography.center.dy - portrait.center.dy).abs(), lessThan(45));
      expect(biography.left - facts.right, closeTo(20, .01));
      final rows = tester.widgetList<HubSection>(find.byType(HubSection)).toList();
      expect(rows[0].hub.title, 'Watched');
      for (final (index, icon) in [(0, Icons.history), (1, Icons.movie_outlined)]) {
        final leading = find.descendant(
          of: find.byType(HubSection).at(index),
          matching: find.byWidgetPredicate((widget) => widget is AppIcon && widget.icon == icon),
        );
        final heading = find.text(rows[index].hub.title);
        expect(leading, findsOneWidget);
        expect(tester.getRect(heading).left - tester.getRect(leading).right, closeTo(tv ? 12 : 8, .01));
      }
      expect(rows[0].hub.items.map((v) => v.title), ['One episode show', 'Started movie']);
      expect(rows[1].hub.items.map((v) => v.title), ['Other movie', 'Unidentified']);
      expect(rows[0].hub.items.every((v) => (v.viewCount ?? 0) == 0), true);
      expect(client.creditPages, [null, secondSource]);
      expect(client.details, isEmpty);
      expect(client.peopleReads, 1);
      expect(tester.getRect(find.text('Other movie')).bottom, greaterThan(950));
      final personCardWidth = tester.getSize(find.byType(MediaCard).first).width;
      // Render an ordinary Home-style shelf at the same viewport width. Its
      // real card geometry should match, including the TV shelf sizing policy.
      await tester.pumpWidget(
        InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(dark: true),
            home: Scaffold(
              body: SingleChildScrollView(
                child: HubSection(
                  hub: rows.first.hub,
                  focusMemory: HubFocusMemory(),
                  icon: Icons.movie_outlined,
                  autoScroll: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(personCardWidth, closeTo(tester.getSize(find.byType(MediaCard).first).width, .01));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('full-size first-row posters stay visible when returning from lower rows on short screens', (
    tester,
  ) async {
    for (final tv in [false, true]) {
      final client = PersonFixture();
      await mount(tester, client, tv: tv, size: const Size(1100, 600));
      await tester.pumpAndSettle();
      final rows = find.byType(HubSection);
      final first = tester.state<HubSectionState>(rows.first);
      first.requestFocusAt(0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      final row = tester.getRect(rows.first);
      expect(row.top, greaterThanOrEqualTo(0));
      expect(row.bottom, lessThanOrEqualTo(600));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(first.hasFocus, true);
      final returned = tester.getRect(rows.first);
      expect(returned.top, greaterThanOrEqualTo(0));
      expect(returned.bottom, lessThanOrEqualTo(600));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('person Watched includes joint-only movies and started shows without merging personal completion', (
    tester,
  ) async {
    for (final tv in [false, true]) {
      final client = PersonFixture()
        ..customCredits = [
          credit(firstSource, 'Own movie', viewed: true, jointWatches: [jointViewing()]),
          credit(secondSource, 'Joint movie', jointWatches: [jointViewing(watched: 1)]),
          credit(
            '33333333-3333-4333-8333-333333333333',
            'Joint started show',
            series: true,
            jointWatches: [jointViewing(available: 12)],
          ),
          credit('44444444-4444-4444-8444-444444444444', 'Unseen movie', jointWatches: [jointViewing(seen: false)]),
        ];
      await mount(tester, client, tv: tv);
      await tester.pumpAndSettle();
      final rows = tester.widgetList<HubSection>(find.byType(HubSection)).toList();
      expect(rows, hasLength(2));
      expect(rows[0].hub.items.map((item) => item.title), ['Joint movie', 'Joint started show', 'Own movie']);
      expect(rows[1].hub.items.map((item) => item.title), ['Unseen movie']);
      final jointItems = rows[0].hub.items.where((item) => item.title?.startsWith('Joint') ?? false).toList();
      expect(jointItems.every((item) => (item.viewCount ?? 0) == 0), true);
      for (final item in jointItems) {
        final projection = (item.raw!['joint_watches'] as List).single as Map;
        expect(projection['color'], '#12ABCD');
        expect((projection['watch'] as Map)['seen'], true);
      }
      expect(rows.expand((row) => row.hub.items).map((item) => item.id).toSet().length, 4);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('removing a joint projection on reload returns its credit to Other', (tester) async {
    final client = PersonFixture()
      ..customCredits = [
        credit(firstSource, 'Joint movie', jointWatches: [jointViewing()]),
        credit(secondSource, 'Own movie', viewed: true),
      ];
    await mount(tester, client);
    await tester.pumpAndSettle();
    expect(tester.widget<HubSection>(find.byType(HubSection).first).hub.items.length, 2);
    client.customCredits = [credit(firstSource, 'Joint movie'), credit(secondSource, 'Own movie', viewed: true)];
    await tester.state<TedPersonDetailState>(find.byType(TedPersonDetail)).reload();
    await tester.pumpAndSettle();
    final rows = tester.widgetList<HubSection>(find.byType(HubSection)).toList();
    expect(rows[0].hub.items.map((item) => item.title), ['Own movie']);
    expect(rows[1].hub.items.map((item) => item.title), ['Joint movie']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('first filmography row restores the full banner and second row scrolls into view', (tester) async {
    for (final tv in [false, true]) {
      final client = PersonFixture();
      await mount(tester, client, tv: tv);
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.descendant(of: find.byType(TedPersonDetail), matching: find.byType(SingleChildScrollView)).first,
          )
          .controller!;
      final rows = find.byType(HubSection);
      final banner = find.byKey(const ValueKey('person-banner'));
      expect(tester.getSize(banner).height, closeTo(950 * .28 * 1.5, .01));
      expect(scroll.offset, closeTo(0, .01));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, contains('-other'));
      expect(scroll.offset, greaterThan(0));
      expect(tester.getRect(find.text('Other movie')).bottom, lessThanOrEqualTo(950));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, contains('-watched'));
      expect(scroll.offset, closeTo(0, .01));
      tester.state<HubSectionState>(rows.first).requestFocusAt(0);
      await tester.pumpAndSettle();
      // Moving within a focused first row must also reveal the banner after
      // a manual scroll, rather than only responding when the lane is entered.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(0, .01));
      expect(tester.state<HubSectionState>(rows.first).hasFocus, true);
      expect(tester.getRect(banner).top, closeTo(0, .01));
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('empty Watched is hidden and Other appearances becomes the row with bounded hero reveal', (tester) async {
    final client = PersonFixture()..noViewed = true;
    await mount(tester, client, tv: true, size: const Size(1292, 600));
    await tester.pumpAndSettle();
    expect(find.text('Watched'), findsNothing);
    expect(find.byType(HubSection), findsOneWidget);
    expect(tester.widget<HubSection>(find.byType(HubSection)).hub.title, 'Other appearances');
    final scroll = tester
        .widget<SingleChildScrollView>(
          find.descendant(of: find.byType(TedPersonDetail), matching: find.byType(SingleChildScrollView)).first,
        )
        .controller!;
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(tester.getRect(find.byType(HubSection)).bottom, lessThanOrEqualTo(600));
    expect(tester.getRect(find.byKey(const ValueKey('person-banner'))).bottom, greaterThan(0));
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('-other'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a newly inserted Watched shelf keeps the focused Other shelf visible', (tester) async {
    final client = PersonFixture()
      ..noViewed = true
      ..personStatus = 'queued';
    await mount(tester, client);
    await tester.pump(const Duration(milliseconds: 400));
    final other = find.byWidgetPredicate((w) => w is HubSection && w.hub.title == 'Other appearances');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    tester.state<HubSectionState>(other).requestFocusAt(2);
    await tester.pump(const Duration(milliseconds: 250));
    client.noViewed = false;
    client.personStatus = 'ready';
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Watched'), findsOneWidget);
    expect(tester.state<HubSectionState>(other).hasFocus, true);
    expect(tester.getRect(other).bottom, lessThanOrEqualTo(950));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Read more is reached from the first shelf and opens the biography with Enter', (tester) async {
    final client = PersonFixture()..overview = List.filled(150, 'Biography text.').join(' ');
    await mount(tester, client, tv: true);
    await tester.pumpAndSettle();
    final row = find.byType(HubSection).first;
    tester.state<HubSectionState>(row).requestFocusAt(0);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending/failing person load keeps seed data, protects old pages and fences results after disposal', (
    tester,
  ) async {
    final client = PersonFixture()..heldPerson = Completer<TedMetadataSnapshot>();
    await mount(tester, client);
    expect(find.text('Actor'), findsOneWidget);
    expect(find.text('Bruce Wayne'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    client.heldPerson!.complete(client.biography);
    await tester.pump();
    expect(client.creditPages, isEmpty);
    expect(tester.takeException(), isNull);
    final fresh = PersonFixture();
    await mount(tester, fresh);
    await tester.pumpAndSettle();
    fresh.failPage = true;
    await tester.state<TedPersonDetailState>(find.byType(TedPersonDetail)).reload();
    await tester.pumpAndSettle();
    expect(find.text('Other movie'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    fresh.failPage = false;
    fresh.loopPage = true;
    await tester.state<TedPersonDetailState>(find.byType(TedPersonDetail)).reload();
    await tester.pumpAndSettle();
    expect(find.text('TED returned an incomplete filmography.'), findsOneWidget);
    expect(find.text('Other movie'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('person rows restore focus; Escape to movie details focuses Play', (tester) async {
    final client = PersonFixture();
    await mount(tester, client, tv: true, shell: true, size: const Size(1512, 950));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((w) => w is NavigationRailItem && (w.label as Text).data == 'Movies'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MediaCard).first);
    await tester.pumpAndSettle();
    tester.state<TedMovieDetailState>(find.byType(TedMovieDetail)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    for (var i = 0; i < 4 && FocusManager.instance.primaryFocus?.debugLabel != 'ted_cast_row'; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ted_cast_row');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(TedPersonDetail), findsOneWidget);
    expect(find.byType(NavigationRailItem), findsNWidgets(10));
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('-watched'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('-watched'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('-other'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('-other'));
    // Opening an appearance keeps the person page mounted, then returns to its row.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(TedMovieDetail), findsOneWidget);
    expect(find.byType(TedPersonDetail), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TedPersonDetail), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('-other'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TedMovieDetail), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ted_detail_play');
    expect(tester.widget<CastMemberStrip>(find.byType(CastMemberStrip)).onMemberTap, isNotNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a late appearance response cannot navigate after the credential owner changes', (tester) async {
    final old = PersonFixture()..heldAppearance = Completer<TedTitle>();
    final fresh = PersonFixture();
    addTearDown(old.auth.close);
    addTearDown(fresh.auth.close);
    await TvDetectionService.getInstance(forceTv: true);
    tester.view.physicalSize = const Size(1292, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var client = old;
    var opened = 0;
    late StateSetter change;
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              change = setState;
              return TedPersonDetail(
                client: client,
                person: const TedMetadataPerson(id: firstSource, name: 'Actor', type: 'Actor'),
                origin: client.data(const TedMediaIdentity('movie', 'tt4000000')),
                horizontalInset: 40,
                onClose: () {},
                onSidebar: () {},
                onHeader: () {},
                onOpen: (_) => opened++,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Other movie'));
    await tester.tap(find.text('Other movie'));
    await tester.pump();
    change(() => client = fresh);
    await tester.pump();
    await tester.pump();
    old.heldAppearance!.complete(old.data(const TedMediaIdentity('movie', 'tt5000003')));
    await tester.pump();
    await tester.pump();
    expect(opened, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow person layout remains scrollable without overflow; biography modal closes independently', (
    tester,
  ) async {
    final client = PersonFixture()..overview = List.filled(60, 'A detailed biography.').join(' ');
    await mount(tester, client, size: const Size(390, 844));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read more'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.text(client.overview), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TedPersonDetail), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
