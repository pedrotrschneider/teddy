import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_cached_poster.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'package:plezy/ted/ted_presentation.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:plezy/theme/mono_theme.dart';
import '../test_helpers/prefs.dart';
import 'ted_auth_test.dart' show MemoryStore, pair;
import 'ted_catalog_test.dart' show CatalogFixture, titleData;
import 'ted_home_banner_test.dart' show pixel;

class CachedArtClient extends CatalogFixture {
  int reads = 0;
  Completer<Uint8List?> pending = Completer<Uint8List?>();
  @override
  Future<Uint8List?> metadataImage(String id) {
    reads++;
    return pending.future;
  }
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });
  test('native home contains the new personal row and supports its paginated endpoint', () async {
    final now = DateTime.utc(2026, 10, 13);
    var omit = false;
    final rows = [
      for (final id in ['continue-watching', 'new-releases', 'next-up', 'popular-movie', 'popular-series'])
        {'id': id, 'titles': <Object>[], 'unavailable': false, 'issues': <Object>[]},
    ];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return http.Response(jsonEncode(pair(now)), 200);
        if (r.url.path.contains('/catalog/')) {
          return http.Response(jsonEncode({'titles': [], 'next_skip': null}), 200);
        }
        expect(r.url.path, startsWith('/api/client/v1/rows/'));
        if (r.url.queryParameters.containsKey('after')) {
          expect(r.url.path, '/api/client/v1/rows/new-releases');
          expect(r.url.queryParameters['after'], 'saved-cursor');
        }
        if (omit && r.url.path.endsWith('/new-releases')) return http.Response('{}', 200);
        return http.Response(jsonEncode({'titles': [], 'issues': [], 'next_after': ''}), 200);
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Desktop');
    final client = TedClient(auth);
    final home = await client.home();
    expect(home.map((r) => r.id), rows.map((r) => r['id']));
    expect(home.any((r) => r.unavailable), false);
    expect((await client.personal('new-releases', after: 'saved-cursor')).titles, isEmpty);
    omit = true;
    final partial = await client.home();
    expect(partial.where((r) => r.unavailable).map((r) => r.id), ['new-releases']);
    await expectLater(client.personal('new-releases'), throwsA(isA<TedFailure>()));
  });
  testWidgets('vertical movie and show cards show Cinemeta IMDb in gold before the year without fabricating a score', (
    tester,
  ) async {
    final client = CatalogFixture();
    addTearDown(client.auth.close);
    final presentation = TedPresentation(client);
    for (final kind in ['movie', 'series']) {
      final data = titleData(kind: kind);
      (data['metadata'] as Map)['imdb_rating'] = 8.4;
      final title = TedTitle.fromJson(data);
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          home: Scaffold(
            body: Center(child: MediaCard(item: presentation.item(title), width: 160, height: 300)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(
        find.byWidgetPredicate((w) => w is Text && w.textSpan?.toPlainText() == '★ 8.4 · 2026'),
      );
      expect(((text.textSpan as TextSpan).children!.first as TextSpan).style!.color, const Color(0xFFFFD166));
    }
    final plain = TedTitle.fromJson(titleData());
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(body: MediaCard(item: presentation.item(plain), width: 160, height: 300)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('★'), findsNothing);
    expect(find.text('2026'), findsOneWidget);
  });
  testWidgets('cached posters retain their fallback while loading or failing and reload a new digest', (tester) async {
    final client = CachedArtClient();
    addTearDown(client.auth.close);
    Future<void> draw(String tag) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 240,
            child: TedCachedPoster(
              client: client,
              asset: TedMetadataAsset(
                '11111111-1111-4111-8111-111111111111',
                'Primary',
                0,
                'ready',
                tag: tag,
                userModified: true,
              ),
              fallback: '',
            ),
          ),
        ),
      ),
    );
    await draw('a');
    await tester.pump();
    expect(find.byType(OptimizedMediaImage), findsOneWidget);
    client.pending.completeError(const TedFailure('unavailable'));
    await tester.pumpAndSettle();
    expect(find.byType(OptimizedMediaImage), findsOneWidget);
    client.pending = Completer<Uint8List?>();
    await draw('b');
    await tester.pump();
    expect(client.reads, 2);
    client.pending.complete(pixel);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
