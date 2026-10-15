import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_source_models.dart';
import 'package:plezy/ted/ted_sources.dart';
import 'package:plezy/ted/ted_focus_region.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;

const media = TedMediaIdentity('episode', 'tt1234567:1:2');
const sourceId = '11111111-1111-4111-8111-111111111111';
const sessionId = '22222222-2222-4222-8222-222222222222';
Map<String, dynamic> sourcePage() => {
  'media': media.toJson(),
  'mode': 'addons',
  'mapped_ready': false,
  'sources': [
    {'id': sourceId, 'addon': 'Fixture add-on', 'name': '720p', 'description': 'Direct file'},
  ],
  'issues': [
    {'addon': 'Other add-on', 'code': 'addon_unavailable'},
  ],
  'auto_select': sourceId,
};
Map<String, dynamic> session() => {
  'id': sessionId,
  'media': media.toJson(),
  'media_url': '/api/client/v1/playback/sessions/$sessionId/media',
  'source': 'addon',
  'duration_ms': 0,
  'resume_ms': 8000,
  'audio_languages': ['en'],
  'subtitles': [
    {'url': '/api/client/v1/playback/sessions/$sessionId/subtitles/0', 'language': 'eng', 'label': 'English'},
  ],
};
void main() {
  testWidgets('Reload replaces handles and tolerates a provider disappearing from the selected filter', (tester) async {
    final old = TedSourcePage.fromJson({...sourcePage(), 'issues': []}, media);
    await tester.pumpWidget(
      MaterialApp(
        home: TedSourcePicker(page: old, onReload: () async => old.withChoices([])),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-addon-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixture add-on').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-$sourceId')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed Reload keeps usable source cards and reports failure', (tester) async {
    final old = TedSourcePage.fromJson({...sourcePage(), 'issues': []}, media);
    await tester.pumpWidget(
      MaterialApp(
        home: TedSourcePicker(page: old, onReload: () async => throw const TedFailure('unavailable')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-$sourceId')), findsOneWidget);
    expect(find.text(const TedFailure('unavailable').message), findsOneWidget);
  });

  test('simultaneous prefetch and details share lookup; a later reload fetches anew', () async {
    final now = DateTime.utc(2026, 10, 14);
    var calls = 0;
    final entered = Completer<void>(), release = Completer<void>();
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return response(pair(now));
        calls++;
        if (calls == 1) {
          entered.complete();
          await release.future;
        }
        return response(sourcePage());
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = TedClient(auth);
    final first = client.stremioSources(media, preferredAddonId: 'a' * 64);
    await entered.future;
    final second = client.stremioSources(media);
    release.complete();
    expect((await first).choices.single.id, sourceId);
    expect((await second).choices.single.id, sourceId);
    expect(calls, 1);
    await client.stremioSources(media);
    expect(calls, 2);
  });

  test('empty source wording distinguishes failed lookup from no supported results', () {
    final failed = TedSourcePage.fromJson({...sourcePage(), 'sources': [], 'auto_select': null}, media);
    expect(failed.lookupUnavailable, isTrue);
    expect(failed.withChoices([]).emptyMessage, contains('Retry'));
    final empty = TedSourcePage.fromJson({...sourcePage(), 'sources': [], 'auto_select': null, 'issues': []}, media);
    expect(empty.lookupUnavailable, isFalse);
    expect(empty.emptyMessage, contains('torrents through Real-Debrid'));
  });
  testWidgets('All navigates ordered categories both ways even when earlier cards are scrolled offscreen', (
    tester,
  ) async {
    final ids = [for (var i = 0; i < 5; i++) '11111111-1111-4111-8111-${i.toString().padLeft(12, '0')}'];
    final page = TedSourcePage(
      false,
      false,
      [
        for (var i = 0; i < ids.length; i++)
          TedSourceChoice(
            ids[i],
            'Fixture',
            'Release $i',
            List.filled(8, 'A description line').join('\n'),
            favorite: i == 0,
            recentRank: i == 1 ? 1 : 0,
          ),
      ],
      [],
      null,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: Builder(
          builder: (context) => TextButton(onPressed: () => chooseTedSource(context, page), child: const Text('Open')),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-addon-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All').last);
    await tester.pumpAndSettle();
    Future<void> move(LogicalKeyboardKey key, int? index) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus!;
      if (index == null) {
        expect(focus.context!.findAncestorWidgetOfExactType<DropdownButton<String>>(), isNotNull);
      } else {
        expect(focus.context!.findAncestorWidgetOfExactType<OutlinedButton>()?.key, ValueKey('source-${ids[index]}'));
        final viewport = tester.getRect(find.byType(SingleChildScrollView));
        expect(focus.rect.top, greaterThanOrEqualTo(viewport.top));
      }
    }

    for (var i = 0; i < 5; i++) {
      await move(LogicalKeyboardKey.arrowDown, i);
    }
    for (var i = 3; i >= 0; i--) {
      await move(LogicalKeyboardKey.arrowUp, i);
    }
    await move(LogicalKeyboardKey.arrowUp, null);
    await move(LogicalKeyboardKey.arrowDown, 0);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<OutlinedButton>()?.key,
      ValueKey('source-${ids[1]}'),
    );
  });
  testWidgets('Favorites and Recent dropdown labels include their star and Continue Watching history icons', (
    tester,
  ) async {
    final page = TedSourcePage(
      false,
      false,
      [const TedSourceChoice(sourceId, 'Fixture', 'Release', '', favorite: true, recentRank: 1)],
      [],
      null,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: Builder(
          builder: (context) => TextButton(onPressed: () => chooseTedSource(context, page), child: const Text('Open')),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final dropdown = tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('source-addon-filter')));
    // Check the selectable menu entries, including the inactive Recent category.
    await tester.tap(find.byKey(dropdown.key!));
    await tester.pumpAndSettle();
    for (final entry in [('Favorites', Icons.star), ('Recent', Icons.history)]) {
      final row = find.ancestor(of: find.text(entry.$1).last, matching: find.byType(Row)).first;
      expect(find.descendant(of: row, matching: find.byIcon(entry.$2)), findsOneWidget);
    }
  });
  test('shared preference fields validate ranks and matching preferred handles', () {
    final value = {
      ...sourcePage(),
      'preferred_source': sourceId,
      'sources': [
        {
          ...(sourcePage()['sources'] as List).first as Map<String, dynamic>,
          'source_key': 'a' * 64,
          'favorite_key': 'b' * 64,
          'favorite': true,
          'recent_rank': 1,
        },
      ],
    };
    final page = TedSourcePage.fromJson(value, media);
    expect(page.preferredSource, sourceId);
    expect(page.choices.single.favorite, true);
    for (final patch in [
      {'preferred_source': sessionId},
      {
        'sources': [
          {...(value['sources'] as List).first as Map<String, dynamic>, 'recent_rank': 4},
        ],
      },
    ]) {
      expect(() => TedSourcePage.fromJson({...value, ...patch}, media), throwsA(isA<TedFailure>()));
    }
  });
  testWidgets('shared favorites default first; All groups without duplication and stars work with the keyboard', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 10, 10);
    var changes = 0;
    final held = Completer<void>();
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/client/v1/playback/sources/$sourceId/favorite');
        expect(jsonDecode(request.body), {'favorite': false});
        changes++;
        await held.future;
        return response({'favorite': false, 'favorite_key': 'b' * 64});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final page = TedSourcePage(
      false,
      false,
      [
        TedSourceChoice(
          sourceId,
          'Fixture',
          'Favorite release',
          '',
          favoriteKey: 'b' * 64,
          sourceKey: 'a' * 64,
          favorite: true,
          recentRank: 1,
        ),
        TedSourceChoice(
          sessionId,
          'Fixture',
          'Recent release',
          '',
          favoriteKey: 'c' * 64,
          sourceKey: 'd' * 64,
          recentRank: 2,
        ),
        const TedSourceChoice('33333333-3333-4333-8333-333333333333', 'Fixture', 'Other release', ''),
      ],
      [],
      null,
      preferredSource: sourceId,
    );
    TedSourcePage? changed;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => chooseTedSource(context, page, client: TedClient(auth), onChanged: (p) => changed = p),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Favorite release'), findsOneWidget);
    expect(find.text('Recent release'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('source-addon-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All').last);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<OutlinedButton>()?.key,
      const ValueKey('source-$sourceId'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<IconButton>()?.key,
      const ValueKey('favorite-$sourceId'),
    );
    held.complete();
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<IconButton>()?.key,
      const ValueKey('favorite-$sourceId'),
    );
    expect(changes, 1);
    expect(changed!.choices.first.favorite, false);
    for (final name in ['Favorite release', 'Recent release', 'Other release']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Other sources'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Choose a source'), findsNothing);
  });
  testWidgets('toggling a lower source keeps its reordered card focused and visible', (tester) async {
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        return response({'favorite': (jsonDecode(request.body) as Map)['favorite'], 'favorite_key': '8' * 64});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final page = TedSourcePage(
      false,
      false,
      [
        for (var i = 0; i < 10; i++)
          TedSourceChoice(
            '11111111-1111-4111-8111-${i.toString().padLeft(12, '0')}',
            'Fixture',
            'Release $i',
            'First description line.\nSecond description line.\nThird description line.',
            favoriteKey: i.toString() * 64,
          ),
      ],
      [],
      null,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => chooseTedSource(context, page, client: TedClient(auth)),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    const key = ValueKey('favorite-11111111-1111-4111-8111-000000000008');
    expect(FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<IconButton>()?.key, key);
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus!;
      expect(focus.context!.findAncestorWidgetOfExactType<IconButton>()?.key, key);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      expect(focus.rect.top, greaterThanOrEqualTo(viewport.top));
      expect(focus.rect.bottom, lessThanOrEqualTo(viewport.bottom));
    }
  });
  testWidgets('removing the last filtered favorite returns focus to the source filter', (tester) async {
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient(
        (request) async => request.url.path.endsWith('/login')
            ? response(pair(now))
            : response({'favorite': false, 'favorite_key': 'a' * 64}),
      ),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final page = TedSourcePage(
      false,
      false,
      [TedSourceChoice(sourceId, 'Fixture', 'Favorite release', '', favorite: true, favoriteKey: 'a' * 64)],
      [],
      null,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => chooseTedSource(context, page, client: TedClient(auth)),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Favorite release'), findsNothing);
    expect(
      FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<DropdownButton<String>>(),
      isNotNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Choose a source'), findsNothing);
  });
  for (final oled in [false, true]) {
    testWidgets('source cards are lighter than the ${oled ? 'OLED' : 'dark'} modal and brighten on focus', (
      tester,
    ) async {
      final theme = monoTheme(dark: true, oled: oled);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => InputModeTracker(child: child!),
          theme: theme,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => chooseTedSource(context, TedSourcePage.fromJson(sourcePage(), media)),
              child: const Text('Open picker'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      final color = tester.widget<AlertDialog>(find.byType(AlertDialog)).backgroundColor!;
      expect(color, theme.colorScheme.surface);
      final card = tester.widget<OutlinedButton>(find.byKey(const ValueKey('source-$sourceId')));
      final normal = card.style!.backgroundColor!.resolve({})!;
      final focused = card.style!.backgroundColor!.resolve({WidgetState.focused})!;
      expect(normal.computeLuminance(), greaterThan(color.computeLuminance()));
      expect(focused.computeLuminance(), greaterThan(normal.computeLuminance()));
    });
  }
  test('explicit provider and beginning requests keep handles private and mapped names bounded', () async {
    final now = DateTime.utc(2026, 10, 10);
    final calls = <Map<String, dynamic>>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        calls.add(body);
        if (request.url.path.endsWith('/sources')) {
          return body['provider'] == 'mapped'
              ? response({
                  'media': media.toJson(),
                  'mode': 'mapped',
                  'mapped_ready': true,
                  'mapped_file_name': 'Movie.mkv',
                  'sources': [],
                  'issues': [],
                })
              : response(sourcePage());
        }
        return response({...session(), 'resume_ms': body['start_from_beginning'] == true ? 0 : 8000});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final client = TedClient(auth);
    expect((await client.mappedSource(media)).mappedFileName, 'Movie.mkv');
    expect((await client.stremioSources(media)).choices.single.id, sourceId);
    expect((await client.createSelectedSession(media, sourceId: sourceId, fromBeginning: true)).resumeMs, 0);
    expect((await client.createSession(media, sourceId: sourceId)).resumeMs, 8000);
    expect(calls.map((c) => c['provider']), ['mapped', 'stremio', null, null]);
    expect(calls[2]['start_from_beginning'], true);
    expect(calls[3].containsKey('start_from_beginning'), false);
    expect(
      () => TedSourcePage.fromJson({...sourcePage(), 'mapped_file_name': '/private/path.mkv'}, media),
      throwsA(isA<TedFailure>()),
    );
  });
  test('expired Stremio session requests relinking while keeping TED sign-in', () async {
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        return response({'code': 'stremio_credentials_rejected'}, 409);
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    await expectLater(
      TedClient(auth).addons(refresh: true),
      throwsA(
        isA<TedFailure>()
            .having((e) => e.code, 'code', 'stremio_credentials_rejected')
            .having((e) => e.message, 'message', contains('Relink Stremio')),
      ),
    );
    expect(auth.signedIn, true);
  });
  testWidgets('installed add-ons expose status and explicitly refresh the account collection', (tester) async {
    final now = DateTime.utc(2026, 10, 10);
    var refreshed = false;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        refreshed = request.url.queryParameters['refresh'] == '1';
        return response({
          'addons': [
            {'id': 'a' * 64, 'name': 'Fixture add-on', 'movie': true, 'episode': true, 'supported': true},
          ],
          'cached': !refreshed,
          'observed_at': now.toIso8601String(),
          'issues': [],
        });
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: TedAddonsScreen(client: TedClient(auth)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fixture add-on'), findsOneWidget);
    expect(find.text('Using saved add-ons while Stremio is unavailable.'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh installed add-ons'));
    await tester.pumpAndSettle();
    expect(refreshed, true);
    expect(find.text('Using saved add-ons while Stremio is unavailable.'), findsNothing);
  });
  test('automatic next episode follows personal-row pages and surfaces missing schedules', () async {
    final now = DateTime.utc(2026, 10, 10);
    var failed = false;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        if (failed) {
          return response({
            'titles': [],
            'next_after': null,
            'issues': [
              {'code': 'schedule_unavailable', 'media': const TedMediaIdentity('series', 'tt1234567').toJson()},
            ],
          });
        }
        final after = request.url.queryParameters['after'];
        if (after == null) return response({'titles': [], 'next_after': 'next-page', 'issues': []});
        expect(after, 'next-page');
        return response({
          'titles': [
            {
              'media': media.toJson(),
              'parent': const TedMediaIdentity('series', 'tt1234567').toJson(),
              'metadata': {
                'series': {'name': 'Fixture'},
                'episode': {'name': 'Next', 'season': 1, 'number': 2},
              },
              'watch_state': {'played': false, 'revision': 0, 'position_ms': 0},
              'local_available': false,
              'mapped_ready': false,
            },
          ],
          'next_after': null,
          'issues': [],
        });
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final client = TedClient(auth);
    expect((await client.nextForShow('tt1234567'))?.media, media);
    failed = true;
    await expectLater(client.nextForShow('tt1234567'), throwsA(isA<TedFailure>()));
  });
  test('source transport uses safe handles and preserves previous-session matching', () async {
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        expect(request.url.host, 'ted.example');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['media'], media.toJson());
        if (request.url.path.endsWith('/sources')) {
          expect(body['previous_session'], sessionId);
          return response(sourcePage());
        }
        expect(body['source_id'], sourceId);
        return response(session());
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final client = TedClient(auth);
    final page = await client.sources(media, previousSession: sessionId);
    expect(page.autoSelect, sourceId);
    expect(page.issues, isEmpty);
    final playback = await client.createSession(media, sourceId: sourceId);
    expect(playback.durationMs, 0);
    expect(playback.resumeMs, 8000);
    expect(playback.subtitles.single.language, 'eng');
  });
  test('untrusted source handles, auto-selection and sidecar URLs are rejected', () {
    expect(
      () => TedSourcePage.fromJson({...sourcePage(), 'auto_select': sessionId}, media),
      throwsA(isA<TedFailure>()),
    );
    expect(
      () => TedSourcePage.fromJson({
        ...sourcePage(),
        'media': const TedMediaIdentity('movie', 'tt1234567').toJson(),
      }, media),
      throwsA(isA<TedFailure>()),
    );
    expect(() => TedPlaybackSession.fromJson({...session(), 'source': 'mapped_rd'}, media), throwsA(isA<TedFailure>()));
    expect(
      () => TedPlaybackSession.fromJson({
        ...session(),
        'subtitles': [
          {'url': 'https://provider.example/secret', 'language': 'en', 'label': 'English'},
        ],
      }, media),
      throwsA(isA<TedFailure>()),
    );
  });
  testWidgets('picker quietly skips failed add-ons and returns a working source handle', (tester) async {
    String? selected;
    final page = TedSourcePage.fromJson(sourcePage(), media);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await chooseTedSource(context, page);
            },
            child: const Text('Sources'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Other add-on'), findsNothing);
    expect(find.textContaining('unavailable'), findsNothing);
    await tester.tap(find.text('720p'));
    await tester.pumpAndSettle();
    expect(selected, sourceId);
  });
  testWidgets('every Down moves and reveals the next source card without alternating missed scrolls', (tester) async {
    final page = TedSourcePage.fromJson({
      ...sourcePage(),
      'auto_select': null,
      'sources': [
        for (var i = 0; i < 14; i++)
          {
            'id': '11111111-1111-4111-8111-${i.toString().padLeft(12, '0')}',
            'addon': 'Fixture',
            'name': 'Source $i',
            'description': 'A long source description\nVideo quality and audio\nRequired source information',
          },
      ],
    }, media);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: Builder(
          builder: (context) =>
              TextButton(onPressed: () => chooseTedSource(context, page), child: const Text('Sources')),
        ),
      ),
    );
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    double previous = 0;
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus!;
      expect(
        focus.context!.findAncestorWidgetOfExactType<OutlinedButton>()?.key,
        ValueKey('source-11111111-1111-4111-8111-${i.toString().padLeft(12, '0')}'),
      );
      final scroll = Scrollable.maybeOf(focus.context!)!;
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      expect(focus.rect.top, greaterThanOrEqualTo(viewport.top));
      expect(focus.rect.bottom, lessThanOrEqualTo(viewport.bottom));
      if (i > 1) expect(scroll.position.pixels, greaterThan(previous));
      previous = scroll.position.pixels;
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('failed add-ons without usable sources retain an actionable empty state', (tester) async {
    final page = TedSourcePage.fromJson({...sourcePage(), 'sources': [], 'auto_select': null}, media);
    var backs = 0;
    String? selected = sourceId;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: Builder(
          builder: (context) => TedFocusRegion(
            autofocus: true,
            onBack: () => backs++,
            child: TextButton(
              onPressed: () async => selected = await chooseTedSource(context, page),
              child: const Text('Sources'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Other add-on'), findsNothing);
    expect(find.textContaining('Some add-ons could not be reached'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Choose a source'), findsNothing);
    expect(selected, isNull);
    expect(backs, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(backs, 1);
  });
  testWidgets('All hides unsupported notices; selecting an installed add-on shows its own results and notice', (
    tester,
  ) async {
    final a = 'a' * 64, b = 'b' * 64;
    final page = TedSourcePage.fromJson({
      ...sourcePage(),
      'addons': [
        {'id': a, 'name': 'Direct add-on', 'movie': true, 'episode': true, 'supported': true},
        {'id': b, 'name': 'Torrent add-on', 'movie': true, 'episode': true, 'supported': true},
      ],
      'sources': [
        {'id': sourceId, 'addon_id': a, 'addon': 'Direct add-on', 'name': '720p', 'description': 'Direct file'},
      ],
      'issues': [
        {'addon_id': b, 'addon': 'Torrent add-on', 'code': 'unsupported_sources'},
      ],
    }, media);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InputModeTracker(child: child!),
        home: Builder(
          builder: (context) =>
              TextButton(onPressed: () => chooseTedSource(context, page), child: const Text('Sources')),
        ),
      ),
    );
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    expect(find.text('720p'), findsOneWidget);
    expect(find.textContaining('returned unsupported'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('source-addon-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Torrent add-on').last);
    await tester.pumpAndSettle();
    expect(find.text('720p'), findsNothing);
    expect(find.textContaining('returned unsupported'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Choose a source'), findsNothing);
  });
  test('hiding failed add-ons preserves validation and other source notices', () {
    final data = {
      ...sourcePage(),
      'issues': [
        {'addon': 'Other add-on', 'code': 'addon_unavailable'},
        {'code': 'addon_collection_cached'},
        {'addon': 'Torrent add-on', 'code': 'unsupported_sources'},
        {'addon': 'Large add-on', 'code': 'source_limit'},
      ],
    };
    final page = TedSourcePage.fromJson(data, media);
    expect(page.choices.single.id, sourceId);
    expect(page.issues, hasLength(3));
    expect(page.issues.join(' '), isNot(contains('Other add-on')));
    for (final issue in [
      {'addon': 'x' * 257, 'code': 'addon_unavailable'},
      {'code': 'unexpected_provider_error'},
    ]) {
      expect(
        () => TedSourcePage.fromJson({
          ...data,
          'issues': [issue],
        }, media),
        throwsA(isA<TedFailure>()),
      );
    }
  });
}
