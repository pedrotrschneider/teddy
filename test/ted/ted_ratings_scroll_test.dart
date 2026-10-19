import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/models/teddy_section.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_movie_detail.dart';
import 'package:plezy/ted/ted_rating.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/hub_section.dart';
import '../test_helpers/prefs.dart';
import 'ted_catalog_test.dart' show CatalogFixture, titleData;

class RatingsFixture extends CatalogFixture {
  final ratings = <String, int>{};
  Completer<void>? refresh;
  final entries = [
    for (var i = 0; i < 7; i++)
      TedTitle.fromJson({
        ...titleData(id: 'tt${4000000 + i}', ready: false),
        'metadata': {'name': 'Film $i', 'year': '2026'},
      }),
  ];
  @override
  Future<TedPersonalPage> collection(String list, {String kind = '', String? after}) async {
    await refresh?.future;
    final rating = int.parse(list.split('/').last);
    return TedPersonalPage(
      [
        for (final title in entries)
          if ((ratings[title.media.id] ?? 0) == rating)
            title.withPreferences(TedTitlePreferences(false, ratings[title.media.id])),
      ],
      null,
      const [],
    );
  }

  @override
  Future<TedTitle> title(TedMediaIdentity media) async => entries.firstWhere((t) => t.media == media);
  @override
  Future<TedTitlePreferences> setTitlePreference(
    TedMediaIdentity media,
    String field, {
    bool? watchlist,
    int? rating,
  }) async {
    if (rating == null) {
      ratings.remove(media.id);
    } else {
      ratings[media.id] = rating;
    }
    return TedTitlePreferences(false, rating);
  }
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    await SettingsService.instance.write(SettingsService.teddyStartupSection, TeddySection.ratings);
    PlatformDetector.debugSetIsDesktopOSOverride(true);
  });
  tearDown(() => PlatformDetector.debugSetIsDesktopOSOverride(null));

  for (final existingShelf in [false, true]) {
    testWidgets(
      'rating from Unrated preserves the viewport with ${existingShelf ? "an existing" : "a new"} category shelf',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final client = RatingsFixture();
        addTearDown(client.auth.close);
        if (existingShelf) client.ratings[client.entries.last.media.id] = 5;
        await tester.pumpWidget(
          InputModeTracker(
            child: MaterialApp(
              theme: monoTheme(dark: true),
              home: Scaffold(
                body: TedBrowseScreen(client: client, onPlay: (_) async {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final unrated = find.byWidgetPredicate((w) => w is HubSection && w.hub.title == 'Unrated');
        InputModeTracker.reportNonPointerInput();
        tester.state<HubSectionState>(unrated).requestFocusAt(0);
        await tester.pumpAndSettle();
        final vertical = Scrollable.of(tester.element(unrated)).position;
        // Deliberately move away from the automatic reveal alignment. Returning
        // must retain this exact view, including when refresh inserts a shelf.
        vertical.jumpTo((vertical.pixels + 60).clamp(vertical.minScrollExtent, vertical.maxScrollExtent));
        await tester.pumpAndSettle();
        final before = tester.getTopLeft(unrated).dy;
        var recordFrames = false;
        final framePositions = <double>[];
        // Persistent callbacks run after drawFrame and before post-frame
        // callbacks. Catch a one-frame jump that pumpAndSettle would conceal.
        WidgetsBinding.instance.addPersistentFrameCallback((_) {
          if (recordFrames && unrated.evaluate().isNotEmpty) framePositions.add(tester.getTopLeft(unrated).dy);
        });
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(TedMovieDetail), findsOneWidget);
        await tester.tap(find.text('Rate'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Good'));
        await tester.pumpAndSettle();
        client.refresh = Completer<void>();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(TedMovieDetail), findsNothing);
        expect(tester.state<HubSectionState>(unrated).hasFocus, isTrue);
        expect(
          tester.getTopLeft(unrated).dy,
          closeTo(before, .1),
          reason: 'Return focus must not reveal the shelf again',
        );
        recordFrames = true;
        client.refresh!.complete();
        await tester.pumpAndSettle();
        recordFrames = false;
        expect(tester.widget<HubSection>(unrated).hub.items.length, existingShelf ? 5 : 6);
        expect(find.byWidgetPredicate((w) => w is HubSection && w.hub.title == 'Good'), findsOneWidget);
        expect(tester.state<HubSectionState>(unrated).hasFocus, isTrue);
        expect(
          tester.getTopLeft(unrated).dy,
          closeTo(before, .1),
          reason: 'The refreshed row must keep its screen position',
        );
        expect(framePositions, isNotEmpty);
        expect(
          framePositions,
          everyElement(closeTo(before, .1)),
          reason: 'Even the first refreshed frame must retain the viewport',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
