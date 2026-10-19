import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_source_cache.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_sources_test.dart' show sourcePage, media, sourceId;

void main() {
  test('v29 upgrade preserves owned downloads and pending reports', () async {
    final dir = await Directory.systemTemp.createTemp('ted-source-cache-upgrade');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/state.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    await db.customStatement("INSERT INTO ted_downloads VALUES('download','scope','media','owned-copy')");
    await db.customStatement("INSERT INTO ted_sessions(id,scope,media) VALUES('session','scope','media')");
    await db.customStatement("INSERT INTO ted_reports(id,session_id,envelope) VALUES('event','session','immutable')");
    await db.customStatement('DROP TABLE ted_source_cache');
    await db.customStatement('DROP TABLE ted_home_cache');
    await db.customStatement('ALTER TABLE ted_sessions DROP COLUMN qualified');
    await db.customStatement('DROP TABLE ted_profile_pictures');
    await db.customStatement('PRAGMA user_version=29');
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await TedSourceCache(db).write('scope', media, {...sourcePage(), 'issues': []});
    expect((await db.customSelect('SELECT value FROM ted_downloads').getSingle()).read<String>('value'), 'owned-copy');
    expect(
      (await db.customSelect('SELECT envelope FROM ted_reports').getSingle()).read<String>('envelope'),
      'immutable',
    );
  });

  test('persistent results survive a new client; explicit reload alone refetches within twelve hours', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    var now = DateTime.utc(2026, 10, 14);
    var lookups = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => DateTime.utc(2026, 10, 14),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login') || r.url.path.endsWith('/refresh')) return response(pair(now));
        lookups++;
        return response({...sourcePage(), 'issues': []});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    var client = TedClient(auth, sourceCache: TedSourceCache(db, now: () => now));
    await client.stremioSources(media);
    now = now.add(const Duration(hours: 11));
    client = TedClient(auth, sourceCache: TedSourceCache(db, now: () => now));
    expect((await client.stremioSources(media)).choices.single.id, sourceId);
    expect(lookups, 1);
    await client.stremioSources(media, forceRefresh: true);
    expect(lookups, 2);
  });

  test('cache expires at twelve hours and isolates account/server/device scopes', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    var now = DateTime.utc(2026, 10, 14);
    final cache = TedSourceCache(db, now: () => now);
    await cache.write('server/account/device', media, {...sourcePage(), 'issues': []});
    expect(await cache.read('other/account/device', media), isNull);
    now = now.add(const Duration(hours: 12));
    expect(await cache.read('server/account/device', media), isNull);
  });

  test('failed empty reload preserves previous results; usable partial results are cached', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final cache = TedSourceCache(db);
    await cache.write('scope', media, sourcePage());
    await cache.write('scope', media, {...sourcePage(), 'sources': [], 'auto_select': null});
    final data = await cache.read('scope', media);
    expect((data!['sources'] as List).length, 1);
    expect(data['_cached'], isTrue);
  });
}
