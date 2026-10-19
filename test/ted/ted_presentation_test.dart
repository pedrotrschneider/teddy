import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_presentation.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/watched_indicator.dart';
import 'package:plezy/widgets/unwatched_count_badge.dart';
import '../test_helpers/prefs.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_catalog_test.dart' show titleData;

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });

  test('wide TED movie cards select a poster when the retained backdrop is empty', () {
    final client = TedClient(TedAuth(store: MemoryStore()));
    addTearDown(client.auth.close);
    final presenter = TedPresentation(client);
    const poster = 'https://images.metahub.space/poster/small/tt1345836/img';
    const backdrop = 'https://images.metahub.space/background/medium/tt1345836/img';
    for (final background in ['', backdrop]) {
      final title = TedTitle.fromJson({
        ...titleData(id: 'tt1345836'),
        'metadata': {'name': 'The Dark Knight Rises', 'poster': poster, 'background': background},
      });
      final item = MediaItem.fromJson(presenter.item(title).toJson());
      expect(
        item.posterThumb(mode: EpisodePosterMode.episodeThumbnail, mixedHubContext: true),
        background.isEmpty ? poster : backdrop,
      );
      expect(item.id, 'movie/tt1345836');
      expect(item.viewOffsetMs, title.positionMs);
    }
  });

  testWidgets('native series counts render the shared completion check and partial badge', (tester) async {
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(store: MemoryStore(), now: () => now, client: MockClient((_) async => response(pair(now))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final presenter = TedPresentation(TedClient(auth));
    for (final watched in [8, 7, 0]) {
      final data = titleData(kind: 'series', played: watched == 8);
      data['watch_state'] = {'played': watched == 8, 'revision': 0, 'position_ms': 0, 'duration_ms': null};
      data['episode_counts'] = {'total': 8, 'watched': watched};
      final item = presenter.item(TedTitle.fromJson(data));
      expect(item.leafCount, 8);
      expect(item.viewedLeafCount, watched);
      expect(MediaItem.fromJson(item.toJson()).unwatchedCount, 8 - watched);
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          home: SizedBox(width: 200, height: 300, child: WatchedIndicator(item: item, showUnwatchedCount: true)),
        ),
      );
      expect(find.byIcon(Symbols.check_rounded), watched == 8 ? findsOneWidget : findsNothing);
      expect(find.byType(UnwatchedCountBadge), watched > 0 && watched < 8 ? findsOneWidget : findsNothing);
    }
  });

  testWidgets('never-watched TED series keep accurate cached totals without displaying episode-count badges', (
    tester,
  ) async {
    final presenter = TedPresentation(TedClient(TedAuth(store: MemoryStore())));
    addTearDown(presenter.client.auth.close);
    for (final show in [('MobLand', 14), ('War', 2), ('American Horror Story', 140)]) {
      final data = titleData(kind: 'series');
      data['metadata'] = {'name': show.$1};
      data['watch_state'] = {'played': false, 'revision': 0, 'position_ms': 0};
      data['episode_counts'] = {'total': show.$2, 'watched': 0};
      final item = MediaItem.fromJson(presenter.item(TedTitle.fromJson(data)).toJson());
      expect(item.leafCount, show.$2);
      expect(item.viewedLeafCount, 0);
      expect(item.unwatchedCount, show.$2);
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          home: SizedBox(width: 200, height: 300, child: WatchedIndicator(item: item, showUnwatchedCount: true)),
        ),
      );
      expect(find.byType(UnwatchedCountBadge), findsNothing, reason: show.$1);
      expect(find.byIcon(Symbols.check_rounded), findsNothing, reason: show.$1);
    }
  });

  testWidgets('TED badge transitions track current episode completion while Plezy backend behavior is preserved', (
    tester,
  ) async {
    final presenter = TedPresentation(TedClient(TedAuth(store: MemoryStore())));
    addTearDown(presenter.client.auth.close);
    for (final watched in [0, 1, 3, 4, 0]) {
      final data = titleData(kind: 'series');
      data['watch_state'] = {'played': watched == 4, 'revision': 1, 'position_ms': 0};
      data['episode_counts'] = {'total': 4, 'watched': watched};
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          home: SizedBox(
            width: 200,
            height: 300,
            child: WatchedIndicator(item: presenter.item(TedTitle.fromJson(data)), showUnwatchedCount: true),
          ),
        ),
      );
      if (watched > 0 && watched < 4) {
        final badge = tester.widget<UnwatchedCountBadge>(find.byType(UnwatchedCountBadge));
        expect(badge.count, watched);
        expect(badge.total, 4);
        expect(find.text('$watched / 4'), findsOneWidget);
      } else {
        expect(find.byType(UnwatchedCountBadge), findsNothing);
      }
      expect(find.byIcon(Symbols.check_rounded), watched == 4 ? findsOneWidget : findsNothing);
    }
    for (final item in [
      const MediaItem.plex(id: 'plex-show', kind: MediaKind.show, title: 'Plex show', leafCount: 4, viewedLeafCount: 0),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          home: SizedBox(width: 200, height: 300, child: WatchedIndicator(item: item, showUnwatchedCount: true)),
        ),
      );
      expect(tester.widget<UnwatchedCountBadge>(find.byType(UnwatchedCountBadge)).count, 4);
    }
  });

  testWidgets('unknown and zero released episode totals do not display a watched check', (tester) async {
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(store: MemoryStore(), now: () => now, client: MockClient((_) async => response(pair(now))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final presenter = TedPresentation(TedClient(auth));
    for (final known in [false, true]) {
      final data = titleData(kind: 'series');
      data['watch_state'] = {'played': false, 'revision': 0, 'position_ms': 0, 'duration_ms': null};
      if (known) data['episode_counts'] = {'total': 0, 'watched': 0};
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          home: SizedBox(
            width: 200,
            height: 300,
            child: WatchedIndicator(item: presenter.item(TedTitle.fromJson(data)), showUnwatchedCount: true),
          ),
        ),
      );
      expect(find.byIcon(Symbols.check_rounded), findsNothing);
      expect(find.byType(UnwatchedCountBadge), findsNothing);
    }
  });

  test('native episode aggregates reject malformed, inconsistent and non-series counts', () {
    for (final data in [
      {
        ...titleData(kind: 'series'),
        'episode_counts': {'total': 8, 'watched': 9},
      },
      {
        ...titleData(kind: 'series'),
        'episode_counts': {'total': 8, 'watched': -1},
      },
      {
        ...titleData(kind: 'series'),
        'episode_counts': {'total': 8, 'watched': 8},
      },
      {
        ...titleData(kind: 'series'),
        'episode_counts': {'total': 8},
      },
      {
        ...titleData(),
        'episode_counts': {'total': 8, 'watched': 0},
      },
    ]) {
      expect(() => TedTitle.fromJson(data), throwsA(isA<TedFailure>()));
    }
  });

  test('shared media keeps TED identity, watch units and episode hierarchy through serialization', () async {
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(store: MemoryStore(), now: () => now, client: MockClient((_) async => response(pair(now))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final presenter = TedPresentation(TedClient(auth));
    final data = titleData(kind: 'episode', id: 'tt1234567:2:3', played: true);
    data['parent'] = {'kind': 'series', 'id': 'tt1234567'};
    data['metadata'] = {
      'episode': {'name': 'Three', 'season': 2, 'number': 3, 'image': 'https://images.metahub.space/episode.jpg'},
      'series': {'name': 'The show'},
      'poster': 'https://images.metahub.space/poster.jpg',
    };
    final title = TedTitle.fromJson(data), item = presenter.item(TedTitle.fromJson(data));
    expect(item.backend, MediaBackend.ted);
    expect(item.kind, MediaKind.episode);
    expect(item.id, 'episode/tt1234567:2:3');
    expect(item.grandparentId, 'series/tt1234567');
    expect(item.grandparentTitle, 'The show');
    expect(item.parentIndex, 2);
    expect(item.index, 3);
    expect(item.thumbPath, title.episodePoster);
    expect(item.viewOffsetMs, 7000);
    expect(item.durationMs, 100000);
    expect(item.viewCount, 1);
    expect(MediaItem.fromJson(item.toJson()).toJson(), item.toJson());
    expect(presenter.hub(TedHomeRow('continue-watching', [title], false, [])).isContinueWatchingHub, true);
    expect(TedPresentation.capabilities.videoTranscoding, false);
  });

  test('UI scope survives token rotation and separates users and servers', () async {
    final now = DateTime.utc(2026, 10, 10);
    var rotation = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((_) async => response(pair(now, suffix: String.fromCharCode(97 + rotation++)))),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final p = TedPresentation(TedClient(auth)), title = TedTitle.fromJson(titleData());
    final key = p.item(title).globalKey;
    await auth.refresh();
    expect(p.item(title).globalKey, key);
    final other = TedAuth(store: MemoryStore(), now: () => now, client: MockClient((_) async => response(pair(now))));
    addTearDown(other.close);
    await other.login('https://other.example', 'fixture', '', 'Desktop');
    expect(TedPresentation(TedClient(other)).item(title).globalKey, isNot(key));
    final otherUser = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((_) async => response(pair(now, userId: 2))),
    );
    addTearDown(otherUser.close);
    await otherUser.login('https://ted.example', 'another-fixture', '', 'Desktop');
    expect(TedPresentation(TedClient(otherUser)).item(title).globalKey, isNot(key));
    expect(p.item(title).toJson().toString(), isNot(contains('ted_a_')));
    expect(p.item(title).toJson().toString(), isNot(contains('ted_r_')));
  });
}
