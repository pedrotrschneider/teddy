import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_profile_avatar.dart';
import 'package:plezy/ted/ted_user_avatar.dart';
import 'package:plezy/ted/ted_user_watch.dart';
import 'package:plezy/widgets/watched_indicator.dart';
import 'package:plezy/widgets/media_progress_bar.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_profile_pictures_test.dart' show picture;

Map<String, dynamic> indicator({int watched = 0, int available = 1, double? progress, String version = ''}) => {
  'rating': null,
  'account_id': 2,
  'name': 'Clara',
  'avatar_version': version,
  'watch': {'seen': true, 'watched': watched, 'available': available, 'progress': progress},
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('peer payload validates and never changes personal filmography classification', () {
    final raw = indicator(progress: 25);
    expect(TedUserWatch.fromJson(raw).toJson(), raw);
    for (final bad in [
      {...raw, 'account_id': 0},
      {...raw, 'avatar_version': 'private-url'},
      indicator(watched: 2),
      indicator(progress: 101),
    ]) {
      expect(() => TedUserWatch.fromJson(bad), throwsA(isA<TedFailure>()));
    }
    final entry = TedFilmographyEntry.fromJson({
      'item': {'Id': '11111111-1111-4111-8111-111111111111', 'Type': 'Movie', 'Name': 'Movie'},
      'watchlist': false,
      'user_rating': null,
      'identity_status': 'ready',
      'media': {'kind': 'movie', 'id': 'tt1234567'},
      'watched': false,
      'viewed': false,
      'roles': [],
      'images': [],
      'user_watches': [raw],
    });
    expect(entry.userWatches.single.progress, 25);
    expect(entry.hasViewing, isFalse);
  });
  test('avatar requests deduplicate, retry cosmetic failure after a minute and isolate profiles', () async {
    var now = DateTime.utc(2026, 10, 17), calls = 0;
    final bytes = await picture();
    var status = 503;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return response(pair(now, userId: r.url.host == 'other.example' ? 3 : 1));
        expect(r.url.path, '/api/client/v1/accounts/2/avatar');
        expect(r.headers['Authorization'], startsWith('Bearer ted_a_'));
        calls++;
        return http.Response.bytes(
          status == 200 ? bytes : [],
          status,
          headers: {'x-ted-compatibility-version': '0.3', 'content-type': 'image/png'},
        );
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture');
    final client = TedClient(auth), watch = TedUserWatch.fromJson(indicator(version: 'a' * 64));
    expect(await Future.wait([client.userPicture(watch), client.userPicture(watch)]), [null, null]);
    expect(calls, 1);
    status = 200;
    expect(await client.userPicture(watch), isNull);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 1));
    expect(await client.userPicture(watch), bytes);
    expect(calls, 2);
    expect(await client.userPicture(watch), bytes);
    expect(calls, 2);
    await auth.login('https://other.example', 'fixture', '', 'Fixture');
    expect(await client.userPicture(watch), bytes);
    expect(calls, 3);
  });
  testWidgets('peer badges retain an avatar with partial counts or progress, without a completion check', (
    tester,
  ) async {
    for (final (watched, total, progress, episodes, label) in [
      (0, 1, 25.0, false, '25%'),
      (2, 3, null, true, '2 / 3'),
      (1, 1, null, false, null),
    ]) {
      final watch = TedUserWatch.fromJson(indicator(watched: watched, available: total, progress: progress));
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: TedOtherWatchBadge(watch: watch, size: WatchedIndicatorSize.standard, episodes: episodes),
          ),
        ),
      );
      expect(find.byType(TedProfileAvatar), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      if (label != null) expect(find.text(label), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
      expect(find.byType(MediaProgressBar), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('delayed avatar cannot cross a changed badge identity', (tester) async {
    final now = DateTime.utc(2026, 10, 17), pending = Completer<http.Response>();
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return response(pair(now));
        return pending.future;
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture');
    final client = TedClient(auth);
    final watch = TedUserWatch.fromJson(indicator(version: 'a' * 64));
    Widget avatar(TedUserWatch value) => MaterialApp(
      home: TedUserAvatarScope(
        client: client,
        child: TedUserAvatar(watch: value, diameter: 24),
      ),
    );
    await tester.pumpWidget(avatar(watch));
    expect(find.text('C'), findsOneWidget);
    await tester.pumpWidget(avatar(const TedUserWatch(3, 'Lucas', '', true, 1, 1, null)));
    final bytes = await tester.runAsync(picture);
    pending.complete(
      http.Response.bytes(bytes!, 200, headers: {'x-ted-compatibility-version': '0.3', 'content-type': 'image/png'}),
    );
    await tester.pumpAndSettle();
    expect(find.text('L'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
