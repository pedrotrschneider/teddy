import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_browse_header.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_focus_region.dart';
import 'package:plezy/ted/ted_home_banner.dart';
import 'package:plezy/ted/ted_movie_detail.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_play_button.dart';
import 'package:plezy/ted/ted_source_models.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/cast_member_strip.dart';
import 'package:plezy/widgets/navigation_rail_item.dart';
import '../test_helpers/prefs.dart';
import 'ted_catalog_browse_test.dart' show CatalogBrowseFixture;
import 'ted_catalog_test.dart' show titleData;
import 'ted_keyboard_navigation_test.dart' show focused;
import 'ted_metadata_client_test.dart' show metadataData;

const firstSource = '11111111-1111-4111-8111-111111111111';
const secondSource = '22222222-2222-4222-8222-222222222222';
const addonPage = TedSourcePage(
  false,
  false,
  [
    TedSourceChoice(firstSource, 'First add-on', 'First release', '720p'),
    TedSourceChoice(secondSource, 'Second add-on', 'Second release', '1080p'),
  ],
  [],
  secondSource,
);

class MovieFixture extends CatalogBrowseFixture {
  TedSourcePage sourcePage = addonPage;
  bool mapped = true, failSources = false;
  bool queuedMetadata = false;
  List<Map<String, dynamic>> credits = [];
  Completer<TedMetadataSnapshot>? heldMetadata;
  int metadataReads = 0;
  int mappedReads = 0, sourceReads = 0;
  Completer<TedSourcePage>? heldMapping, heldSources;
  TedTitle data(TedMediaIdentity media) => TedTitle.fromJson({
    ...titleData(kind: media.kind, id: media.id, ready: mapped, played: played),
    'enrichment': {
      ...metadataData(status: queuedMetadata ? 'queued' : 'ready'),
      'item': <String, dynamic>{
        ...metadataData()['item'],
        'Type': media.kind == 'episode'
            ? 'Episode'
            : media.kind == 'series'
            ? 'Series'
            : 'Movie',
        'People': queuedMetadata ? [] : credits,
      },
    },
  });
  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async => [];
  @override
  List<TedTitle> entries(String kind, int skip) => [data(TedMediaIdentity(kind, 'tt4000000'))];
  @override
  Future<TedTitle> title(TedMediaIdentity media) async => data(media);
  @override
  Future<TedMetadataSnapshot> metadata(String id) async {
    metadataReads++;
    return heldMetadata?.future ?? data(const TedMediaIdentity('movie', 'tt4000000')).enrichment!;
  }

  @override
  Future<TedSourcePage> mappedSource(TedMediaIdentity media) async {
    mappedReads++;
    return heldMapping?.future ??
        TedSourcePage(mapped, mapped, [], [], null, mappedFileName: mapped ? 'Movie.2160p.mkv' : '');
  }

  @override
  Future<TedSourcePage> stremioSources(
    TedMediaIdentity media, {
    bool forceRefresh = false,
    String preferredAddonId = '',
    Future<void>? abortTrigger,
  }) async {
    sourceReads++;
    if (failSources) throw const TedFailure('addon_unavailable');
    return heldSources?.future ?? sourcePage;
  }
}

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
  final plays = <(String?, bool)>[], downloads = <String?>[];
  Future<void> mount(
    WidgetTester tester,
    MovieFixture client, {
    bool tv = false,
    Size size = const Size(1920, 1080),
  }) async {
    (await TvDetectionService.getInstance()).setForceTv(tv);
    expect(PlatformDetector.isTV(), tv);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.auth.close);
    plays.clear();
    downloads.clear();
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          key: UniqueKey(),
          // Navigation/action checks settle with reduced motion. The shared
          // Play tests advance fixed frames to verify its continuous pulse.
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          theme: monoTheme(
            dark: true,
          ).copyWith(textTheme: monoTheme(dark: true).textTheme.apply(fontFamily: 'Go Noto Current')),
          home: Scaffold(
            body: TedBrowseScreen(
              client: client,
              onPlay: (_) async {},
              onPlaySelection: (_, source, beginning) async {
                plays.add((source, beginning));
              },
              onDownloadSelection: (_, source) async {
                downloads.add(source);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate((w) => w is NavigationRailItem && w.label is Text && (w.label as Text).data == 'Movies'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MediaCard).first);
    await tester.pump();
    await tester.pump();
  }

  Finder getPlay() => find.descendant(of: find.byType(TedPlayButton), matching: find.byType(FilledButton));
  Finder provider() => find.byType(DropdownButtonFormField<String>);
  for (final kind in ['movie', 'episode']) {
    testWidgets('$kind entry waits for Play and player return focuses Play instead of the previous action', (
      tester,
    ) async {
      plays.clear();
      final client = MovieFixture()..heldMapping = Completer<TedSourcePage>();
      addTearDown(client.auth.close);
      (await TvDetectionService.getInstance()).setForceTv(true);
      tester.view.physicalSize = const Size(1512, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final nav = GlobalKey<NavigatorState>();
      final media = TedMediaIdentity(kind, kind == 'episode' ? 'tt4000000:1:1' : 'tt4000000');
      await tester.pumpWidget(
        InputModeTracker(
          child: MaterialApp(
            navigatorKey: nav,
            theme: monoTheme(dark: true),
            builder: (context, child) =>
                MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
            home: Scaffold(
              body: TedMovieDetail(
                client: client,
                initial: client.data(media),
                horizontalInset: 24,
                onClose: () {},
                onSidebar: () {},
                onHeader: () {},
                onPlay: (_, _, _) async {
                  await nav.currentState!.push<void>(
                    MaterialPageRoute(
                      builder: (context) => Scaffold(
                        body: TextButton(
                          autofocus: true,
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close player'),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.widget<FilledButton>(getPlay()).onPressed, isNull);
      client.heldMapping!.complete(const TedSourcePage(true, true, [], [], null));
      await tester.pumpAndSettle();
      expect(focused(getPlay()), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(focused(find.text('Start from the beginning')), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Close player'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(focused(getPlay()), true);
      expect(tester.takeException(), isNull);
    });
  }
  final cast = [
    {'Id': firstSource, 'Name': 'First Actor', 'Type': 'Actor', 'Role': 'Lead'},
    {'Id': secondSource, 'Name': 'Second Actor', 'Type': 'Actor', 'Role': 'Support'},
    {'Id': '33333333-3333-4333-8333-333333333333', 'Name': 'Director', 'Type': 'Director'},
  ];

  ScrollController detailScroll(WidgetTester tester) => tester
      .widget<SingleChildScrollView>(
        find.descendant(of: find.byType(TedMovieDetail), matching: find.byType(SingleChildScrollView)).first,
      )
      .controller!;

  Future<List<Finder>> stremioControls(WidgetTester tester) async {
    await tester.tap(provider());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stremio').last);
    await tester.pumpAndSettle();
    return [
      find.descendant(of: getPlay(), matching: find.byType(Text)).first,
      find.text('Start from the beginning'),
      find.text('Download'),
      find.text('Mark watched'),
      find.descendant(of: provider(), matching: find.text('Stremio')).first,
      find.text('First release'),
    ];
  }

  testWidgets('every movie action and source control returns to the banner on keyboard/TV focus', (tester) async {
    final client = MovieFixture()..credits = cast;
    await mount(tester, client, tv: true, size: const Size(1512, 950));
    await tester.pumpAndSettle();
    final controls = await stremioControls(tester);
    final scroll = detailScroll(tester);
    expect(scroll.position.maxScrollExtent, greaterThan(80));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final actions = tester.state<TedFocusRegionState>(
      find.descendant(of: find.byType(TedMovieDetail), matching: find.byType(TedFocusRegion)).first,
    );
    for (var i = 0; i < controls.length; i++) {
      scroll.jumpTo(80);
      await tester.pump();
      if (i == 0) {
        actions.requestFocus(first: true);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      }
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(0, .01), reason: 'Control $i');
      expect(focused(controls[i]), true, reason: 'Control $i');
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ted_cast_row');
    expect(scroll.offset, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(0, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('hovering every movie action and source control preserves scroll and keyboard focus', (tester) async {
    final client = MovieFixture()..credits = cast;
    await mount(tester, client, size: const Size(1512, 950));
    await tester.pumpAndSettle();
    final controls = await stremioControls(tester);
    final scroll = detailScroll(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    final focus = FocusManager.instance.primaryFocus;
    for (final control in controls) {
      await mouse.moveTo(const Offset(10, 10));
      scroll.jumpTo(80);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(control));
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(80, .01));
      expect(FocusManager.instance.primaryFocus, same(focus));
    }
    expect(plays, isEmpty);
    expect(downloads, isEmpty);
    expect(client.played, false);
    expect(find.byType(Dialog), findsNothing);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached cast appears immediately in Plezy cards and stays aligned at desktop/TV sizes', (tester) async {
    for (final tv in [false, true]) {
      final client = MovieFixture()..credits = cast;
      await mount(tester, client, tv: tv, size: const Size(1512, 950));
      expect(find.text('Cast'), findsOneWidget);
      expect(find.text('First Actor'), findsOneWidget);
      expect(find.text('Lead'), findsOneWidget);
      expect(find.text('Second Actor'), findsOneWidget);
      expect(find.text('Director'), findsNothing);
      expect(client.metadataReads, 0);
      final castIcon = find.byIcon(Icons.people_rounded);
      expect(castIcon, findsOneWidget);
      expect((tester.getRect(castIcon).left - tester.getRect(getPlay()).left).abs(), lessThan(1));
      expect(tester.getRect(find.text('Cast')).left - tester.getRect(castIcon).right, closeTo(tv ? 12 : 8, .01));
      expect((tester.getRect(find.text('First Actor')).left - tester.getRect(getPlay()).left).abs(), lessThan(1));
      expect(tester.widget<CastMemberStrip>(find.byType(CastMemberStrip)).onMemberTap, isNotNull);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('cast is keyboard accessible, remembers the lane after the rail, and returns to actions or catalogue', (
    tester,
  ) async {
    final client = MovieFixture()..credits = cast;
    await mount(tester, client, tv: true);
    await tester.pumpAndSettle();
    tester.state<TedMovieDetailState>(find.byType(TedMovieDetail)).requestFocus();
    await tester.pumpAndSettle();
    expect(focused(getPlay()), true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ted_cast_row');
    final portrait = tester.getRect(find.text('First Actor'));
    expect(portrait.bottom, lessThan(tester.view.physicalSize.height));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ted_cast_row');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('ted_cast_row'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ted_cast_row');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focused(getPlay()), true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TedMovieDetail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one progressive metadata poll updates the cast without blocking playback', (tester) async {
    final client = MovieFixture()
      ..queuedMetadata = true
      ..credits = cast
      ..heldMetadata = Completer<TedMetadataSnapshot>();
    await mount(tester, client);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Loading cast…'), findsOneWidget);
    expect(tester.widget<FilledButton>(getPlay()).onPressed, isNotNull);
    expect(client.metadataReads, 1);
    client.queuedMetadata = false;
    client.heldMetadata!.complete(client.data(const TedMediaIdentity('movie', 'tt4000000')).enrichment!);
    await tester.pumpAndSettle();
    expect(find.text('Loading cast…'), findsNothing);
    expect(find.text('First Actor'), findsOneWidget);
    expect(client.metadataReads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'details preserves the rail, preloads sources in parallel and enables a ready mapping before add-ons finish',
    (tester) async {
      for (final tv in [false, true]) {
        final client = MovieFixture()
          ..heldMapping = Completer<TedSourcePage>()
          ..heldSources = Completer<TedSourcePage>();
        await mount(tester, client, tv: tv, size: const Size(1512, 950));
        expect(find.byType(TedMovieDetail), findsOneWidget);
        expect(find.byType(NavigationRailItem), findsNWidgets(8));
        expect(find.descendant(of: find.byType(TedBrowseHeader), matching: find.byType(Text)), findsNothing);
        expect(tester.widget<TedHomeBanner>(find.byType(TedHomeBanner)).catalogPreview, true);
        expect(client.mappedReads, 1);
        expect(client.sourceReads, 1);
        expect(tester.widget<FilledButton>(getPlay()).onPressed, isNull);
        client.heldMapping!.complete(const TedSourcePage(true, true, [], [], null, mappedFileName: 'Movie.2160p.mkv'));
        await tester.pump();
        await tester.pump();
        expect(tester.widget<FilledButton>(getPlay()).onPressed, isNotNull);
        expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('movie-source-file'))).onPressed, isNull);
        client.heldSources!.complete(addonPage);
        await tester.pumpAndSettle();
        await tester.tap(getPlay());
        await tester.pumpAndSettle();
        expect(plays.last, (null, false));
        await tester.tap(find.text('Start from the beginning'));
        await tester.pumpAndSettle();
        expect(plays.last, (null, true));
        await tester.tap(find.text('Download'));
        await tester.pumpAndSettle();
        expect(downloads.single, null);
        await tester.tap(find.text('Mark watched'));
        await tester.pumpAndSettle();
        expect(client.played, true);
        expect(find.text('Mark unwatched'), findsOneWidget);
        final pill = tester.getRect(getPlay());
        expect((tester.getRect(provider()).center.dy - pill.center.dy).abs(), lessThan(4));
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('shared preferred release is selected on entry while explicit selection remains authoritative', (
    tester,
  ) async {
    final client = MovieFixture()
      ..mapped = false
      ..heldSources = Completer<TedSourcePage>();
    await mount(tester, client);
    client.heldSources!.complete(
      TedSourcePage(false, false, addonPage.choices, [], null, preferredSource: secondSource),
    );
    await tester.pumpAndSettle();
    expect(find.text('Second release'), findsOneWidget);
    await tester.tap(getPlay());
    await tester.pumpAndSettle();
    expect(plays.last, (secondSource, false));
    await tester.tap(find.byKey(const ValueKey('movie-source-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-$firstSource')));
    await tester.pumpAndSettle();
    await tester.tap(getPlay());
    await tester.pumpAndSettle();
    expect(plays.last, (firstSource, false));
  });
  testWidgets('unmapped movie defaults to the first returned release; selector and actions keep the chosen release', (
    tester,
  ) async {
    final client = MovieFixture()
      ..mapped = false
      ..heldSources = Completer<TedSourcePage>();
    await mount(tester, client);
    expect(tester.widget<FilledButton>(getPlay()).onPressed, isNull);
    client.heldSources!.complete(
      TedSourcePage.fromJson({
        'media': client.data(const TedMediaIdentity('movie', 'tt4000000')).media.toJson(),
        'mode': 'addons',
        'mapped_ready': false,
        'sources': [
          for (final choice in addonPage.choices)
            {'id': choice.id, 'addon': choice.addon, 'name': choice.name, 'description': choice.description},
        ],
        'issues': [
          {'addon': 'Failed add-on', 'code': 'addon_unavailable'},
        ],
        'auto_select': secondSource,
      }, const TedMediaIdentity('movie', 'tt4000000')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButtonFormField<String>>(provider()).onChanged, isNull);
    expect(find.text('First release'), findsOneWidget);
    expect(find.textContaining('Failed add-on'), findsNothing);
    await tester.tap(getPlay());
    await tester.pumpAndSettle();
    expect(plays.last, (firstSource, false));
    await tester.tap(find.byKey(const ValueKey('movie-source-file')));
    await tester.pumpAndSettle();
    expect(find.text('Choose a source'), findsOneWidget);
    expect(find.textContaining('Failed add-on'), findsNothing);
    await tester.tap(find.text('Second release'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start from the beginning'));
    await tester.pumpAndSettle();
    expect(plays.last, (secondSource, true));
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(downloads.single, secondSource);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TedMovieDetail), findsNothing);
    expect(find.byType(MediaCard), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mapped movie switches explicitly to Stremio; source failure keeps RD and narrow controls accessible', (
    tester,
  ) async {
    final client = MovieFixture()..failSources = true;
    await mount(tester, client, size: const Size(1100, 740));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(getPlay()).onPressed, isNotNull);
    expect(find.text('RD Mapped'), findsOneWidget);
    await tester.tap(provider());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stremio').last);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(getPlay()).onPressed, isNull);
    client.failSources = false;
    await tester.tap(find.text('Retry').first);
    await tester.pumpAndSettle();
    expect(find.text('First release'), findsOneWidget);
    await tester.tap(getPlay());
    await tester.pumpAndSettle();
    expect(plays.last, (firstSource, false));
    tester.state<TedMovieDetailState>(find.byType(TedMovieDetail)).requestFocus();
    await tester.pumpAndSettle();
    expect(focused(getPlay()), true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focused(find.text('Start from the beginning')), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape dismisses only the source picker and restores its control on desktop and TV', (tester) async {
    for (final tv in [false, true]) {
      final client = MovieFixture()..mapped = false;
      await mount(tester, client, tv: tv);
      await tester.pumpAndSettle();
      tester.state<TedMovieDetailState>(find.byType(TedMovieDetail)).requestFocus();
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      final selector = find.byKey(const ValueKey('movie-source-file'));
      expect(focused(selector), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Choose a source'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Choose a source'), findsOneWidget);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Choose a source'), findsNothing);
      expect(find.byType(TedMovieDetail), findsOneWidget);
      expect(find.text('First release'), findsOneWidget);
      expect(focused(selector), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(TedMovieDetail), findsOneWidget);
      expect(find.text('First release'), findsOneWidget);
      // A subsequent independent Escape still leaves details normally.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TedMovieDetail), findsNothing);
      expect(find.byType(MediaCard), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('empty transient lookup recovers in place and chooses first playable source', (tester) async {
    final client = MovieFixture()
      ..mapped = false
      ..failSources = true;
    await mount(tester, client);
    expect(find.byType(TedMovieDetail), findsOneWidget);
    client.failSources = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('First release'), findsOneWidget);
    expect(client.sourceReads, 2);
    await tester.tap(find.byType(TedPlayButton).first);
    await tester.pumpAndSettle();
    expect(plays.last.$1, firstSource);
  });
  for (final kind in ['movie', 'episode']) {
    testWidgets('$kind details allows source selection and playback during partial-source recovery', (tester) async {
      plays.clear();
      final choices = [
        TedSourceChoice(firstSource, 'First add-on', 'First release', '', sourceKey: 'c' * 64),
        TedSourceChoice(secondSource, 'First add-on', 'Second release', '', sourceKey: 'd' * 64),
      ];
      final client = MovieFixture()
        ..mapped = false
        ..sourcePage = TedSourcePage(
          false,
          false,
          choices,
          [],
          null,
          lookupUnavailable: true,
          unavailableAddons: {'a' * 64},
        );
      addTearDown(client.auth.close);
      (await TvDetectionService.getInstance()).setForceTv(true);
      tester.view.physicalSize = const Size(1512, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final media = TedMediaIdentity(kind, kind == 'episode' ? 'tt4000000:1:1' : 'tt4000000');
      await tester.pumpWidget(
        InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(dark: true),
            builder: (context, child) =>
                MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
            home: Scaffold(
              body: TedMovieDetail(
                client: client,
                initial: client.data(media),
                onPlay: (_, source, _) async => plays.add((source, false)),
                onClose: () {},
                onSidebar: () {},
                onHeader: () {},
                horizontalInset: 24,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(client.sourceReads, 1);
      expect(find.text('First release'), findsOneWidget);
      client.heldSources = Completer<TedSourcePage>();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(client.sourceReads, 2, reason: 'Partial failures still retry');
      expect(tester.widget<FilledButton>(getPlay()).onPressed, isNotNull);
      await tester.tap(getPlay());
      await tester.pumpAndSettle();
      expect(plays.last.$1, firstSource, reason: 'Playback starts before the held retry completes');
      expect(client.sourceReads, 2);
      final menu = find.byKey(const ValueKey('movie-source-file'));
      expect(tester.widget<OutlinedButton>(menu).onPressed, isNotNull);
      expect(find.byWidgetPredicate((w) => w is LinearProgressIndicator && w.value == null), findsNothing);
      expect(find.text('Loading sources…'), findsNothing);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text('Second release'), findsOneWidget);
      // A successful retry renews handles while the old picker stays open.
      const renewedSecond = '44444444-4444-4444-8444-444444444444';
      client.heldSources!.complete(
        TedSourcePage(
          false,
          false,
          [
            TedSourceChoice(
              '33333333-3333-4333-8333-333333333333',
              'First add-on',
              'First release',
              '',
              sourceKey: 'c' * 64,
            ),
            TedSourceChoice(renewedSecond, 'First add-on', 'Second release', '', sourceKey: 'd' * 64),
          ],
          [],
          null,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second release').last);
      await tester.pumpAndSettle();
      expect(find.text('Second release'), findsOneWidget);
      await tester.tap(getPlay());
      await tester.pumpAndSettle();
      expect(plays.last.$1, renewedSecond, reason: 'The explicit release survives background handle renewal');
      await tester.pump(const Duration(seconds: 10));
      expect(client.sourceReads, 2, reason: 'A recovered lookup stops retrying');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('a failed background recovery retains playable choices and an accessible source menu', (tester) async {
    final client = MovieFixture()
      ..mapped = false
      ..sourcePage = TedSourcePage(false, false, addonPage.choices, [], null, lookupUnavailable: true);
    await mount(tester, client, tv: true);
    await tester.pumpAndSettle();
    client.heldSources = Completer<TedSourcePage>();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(client.sourceReads, 2);
    client.heldSources!.completeError(const TedFailure('addon_unavailable'));
    await tester.pump();
    await tester.pump();
    final menu = find.byKey(const ValueKey('movie-source-file'));
    expect(tester.widget<OutlinedButton>(menu).onPressed, isNotNull);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Second release'), findsOneWidget);
    expect(client.sourceReads, 2, reason: 'Opening usable cached choices does not start another blocking lookup');
    await tester.tap(find.text('Second release').last);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(getPlay()).onPressed, isNotNull);
    await tester.tap(getPlay());
    await tester.pumpAndSettle();
    expect(plays.last.$1, secondSource);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets('leaving details cancels its scheduled provider recovery', (tester) async {
    final client = MovieFixture()
      ..mapped = false
      ..failSources = true;
    await mount(tester, client);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final reads = client.sourceReads;
    await tester.pump(const Duration(seconds: 5));
    expect(client.sourceReads, reads);
    expect(find.byType(TedMovieDetail), findsNothing);
  });
}
