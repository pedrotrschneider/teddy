import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_home_cache.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_catalog_test.dart' show titleData;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cached overlaps stay in New Releases during independent refresh and failures without erasing snapshots',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final cache = TedHomeCache(db);
      final pending = <String, Completer<http.Response>>{};
      final auth = TedAuth(
        store: MemoryStore(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/login')) return response(pair(DateTime.now()));
          return pending.putIfAbsent(request.url.path, () => Completer<http.Response>()).future;
        }),
      );
      addTearDown(auth.close);
      await auth.login('https://ted.example', 'fixture', '', 'Home');
      final scope = tedOfflineScope(auth)!;
      final episode = titleData(kind: 'episode', id: 'tt1234567:1:1');
      for (final id in ['next-up', 'new-releases']) {
        await cache.write(scope, {
          'id': id,
          'titles': [episode],
          'issues': [],
          'unavailable': false,
        });
      }
      final updates = <List<TedHomeRow>>[];
      final request = TedClient(auth, homeCache: cache).home(onUpdate: updates.add);
      while (pending.length < 6) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(updates.first.singleWhere((row) => row.id == 'new-releases').titles, hasLength(1));
      expect(updates.first.singleWhere((row) => row.id == 'next-up').titles, isEmpty);
      pending['/api/client/v1/rows/new-releases']!.complete(response({'error': 'unavailable'}, 503));
      for (final entry in pending.entries.where((entry) => !entry.key.endsWith('/new-releases'))) {
        entry.value.complete(
          response({
            'titles': entry.key.endsWith('/next-up') ? [episode] : [],
            'issues': [],
          }),
        );
      }
      final result = await request;
      for (final rows in [...updates, result]) {
        expect(rows.singleWhere((row) => row.id == 'next-up').titles, isEmpty);
        expect(rows.singleWhere((row) => row.id == 'new-releases').titles, hasLength(1));
      }
      // Failed/partial shelves keep their independent persisted data. An empty
      // successful New Releases response may reveal the retained Next Up item.
      expect((await cache.read(scope, 'next-up'))!.titles, hasLength(1));
      final visible = tedDistinctHomeRows([
        (await cache.read(scope, 'next-up'))!,
        const TedHomeRow('new-releases', [], false, []),
      ]);
      expect(visible.first.titles, hasLength(1));
    },
  );

  test('all six shelves survive restart, appear before refresh, and accept successful empty replacements', () async {
    final dir = await Directory.systemTemp.createTemp('ted-home-cache');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/device.db');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    final pending = <String, Completer<http.Response>>{};
    var hold = false;
    final now = DateTime.utc(2026, 10, 15);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return response(pair(now));
        if (hold) return pending.putIfAbsent(r.url.path, () => Completer<http.Response>()).future;
        return response({
          'titles': [titleData(kind: r.url.path.endsWith('/series') ? 'series' : 'movie')],
          'issues': [],
        });
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Home');
    await TedClient(auth, homeCache: TedHomeCache(db)).home();
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    hold = true;
    final first = Completer<List<TedHomeRow>>();
    final refresh = TedClient(auth, homeCache: TedHomeCache(db)).home(
      onUpdate: (rows) {
        if (!first.isCompleted) first.complete(rows);
      },
    );
    final cached = await first.future;
    expect(cached, hasLength(6));
    expect(cached.every((r) => r.titles.length == 1 && !r.loading), true);
    while (pending.length < 6) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final request in pending.entries) {
      request.value.complete(
        request.key.endsWith('/catalog/movie')
            ? response({'error': 'unavailable'}, 502)
            : response({'titles': [], 'issues': []}),
      );
    }
    final refreshed = await refresh;
    expect(refreshed[4].titles, hasLength(1));
    expect(refreshed[4].unavailable, true);
    expect(refreshed.where((r) => r.id != 'popular-movie').every((r) => r.titles.isEmpty), true);
    pending.clear();
    final second = Completer<List<TedHomeRow>>();
    final failure = TedClient(auth, homeCache: TedHomeCache(db)).home(
      onUpdate: (rows) {
        if (!second.isCompleted) second.complete(rows);
      },
    );
    final retained = await second.future;
    expect(retained[4].titles, hasLength(1));
    expect(retained.every((r) => !r.loading), true);
    expect(retained.where((r) => r.id != 'popular-movie').every((r) => r.titles.isEmpty), true);
    while (pending.length < 6) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final request in pending.values) {
      request.complete(response({'error': 'unavailable'}, 502));
    }
    await failure;
  });

  test('partial failures preserve good shelves and cache stays private to its profile', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final cache = TedHomeCache(db);
    final good = {
      'id': 'next-up',
      'titles': [titleData()],
      'issues': [],
      'unavailable': false,
    };
    await cache.write('a', good);
    await cache.write('b', good);
    await cache.write('a', {
      ...good,
      'titles': [],
      'issues': [
        {'code': 'schedule_unavailable'},
      ],
    });
    expect((await cache.read('a', 'next-up'))!.titles, hasLength(1));
    expect(await cache.read('other-server', 'next-up'), isNull);
    await TedLocalStore(db).purgeProfile('a');
    expect(await cache.read('a', 'next-up'), isNull);
    expect((await cache.read('b', 'next-up'))!.titles, hasLength(1));
  });

  test('v30 upgrade preserves downloads, queued reports and pre-existing resume state', () async {
    final dir = await Directory.systemTemp.createTemp('ted-home-upgrade');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/device.db');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    await db.customStatement("INSERT INTO ted_downloads VALUES('copy','owner','movie','owned')");
    await db.customStatement(
      "INSERT INTO ted_sessions(id,scope,media,last_event) VALUES('s','owner','movie','retained')",
    );
    await db.customStatement("INSERT INTO ted_reports(id,session_id,envelope) VALUES('e','s','immutable')");
    await db.customStatement('DROP TABLE ted_home_cache');
    await db.customStatement('DROP TABLE ted_profile_pictures');
    await db.customStatement('ALTER TABLE ted_sessions DROP COLUMN qualified');
    await db.customStatement('PRAGMA user_version=30');
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    expect((await db.customSelect('SELECT qualified FROM ted_sessions').getSingle()).read<int>('qualified'), 1);
    expect(
      (await db.customSelect('SELECT envelope FROM ted_reports').getSingle()).read<String>('envelope'),
      'immutable',
    );
    expect((await db.customSelect('SELECT value FROM ted_downloads').getSingle()).read<String>('value'), 'owned');
    expect(await TedHomeCache(db).read('owner', 'next-up'), isNull);
  });
}
