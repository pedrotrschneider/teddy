import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_source_models.dart';
import 'package:plezy/ted/ted_playback.dart';
import 'package:plezy/ted/ted_downloads.dart';
import 'package:plezy/ted/ted_download_watch.dart';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/mock_player_channels.dart';
import 'ted_playback_test.dart' show ControlFixture, sessionId;
import 'ted_download_tree_test.dart' show file;
import 'ted_auth_test.dart' show MemoryStore, pair, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
  });
  test('season preference survives migration/reopen, is scoped, and matches only one current add-on group', () async {
    final root = await Directory.systemTemp.createTemp('ted-season-source-');
    addTearDown(() => root.delete(recursive: true));
    final databaseFile = File('${root.path}/device.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(databaseFile));
    var store = TedLocalStore(db);
    const media = TedMediaIdentity('episode', 'tt1234567:1:2');
    final viewing = TedPlaybackSession(
      sessionId,
      media,
      '/media',
      10000,
      0,
      source: 'addon',
      addonId: 'a' * 64,
      bingeKey: 'b' * 64,
    );
    final device = await store.installationDevice();
    // Exercise the production 27 -> current migration with retained device data.
    await db.customStatement('DROP TABLE ted_season_sources');
    await db.customStatement('DROP TABLE ted_track_languages');
    await db.customStatement('DROP TABLE ted_source_cache');
    await db.customStatement('DROP TABLE ted_home_cache');
    await db.customStatement('ALTER TABLE ted_sessions DROP COLUMN qualified');
    await db.customStatement('DROP TABLE ted_profile_pictures');
    await db.customStatement('PRAGMA user_version=27');
    await store.close();
    db = AppDatabase.forTesting(NativeDatabase(databaseFile));
    store = TedLocalStore(db);
    expect(await store.installationDevice(), device);
    await store.rememberSeasonSource('account-a', viewing);
    await store.close();
    db = AppDatabase.forTesting(NativeDatabase(databaseFile));
    store = TedLocalStore(db);
    addTearDown(store.close);
    final saved = await store.seasonSource('account-a', const TedMediaIdentity('episode', 'tt1234567:1:8'));
    expect(saved!.provider, 'stremio');
    expect(await store.seasonSource('account-b', media), isNull);
    expect(await store.seasonSource('account-a', const TedMediaIdentity('episode', 'tt1234567:2:1')), isNull);
    final choice = TedSourceChoice(sessionId, 'Add-on', 'Pack', '', addonId: 'a' * 64, bingeKey: 'b' * 64);
    expect(saved.match(TedSourcePage(false, false, [choice], [], null)), sessionId);
    expect(saved.match(TedSourcePage(false, false, [choice, choice], [], null)), isNull);
    expect(
      saved.match(
        TedSourcePage(
          false,
          false,
          [TedSourceChoice(sessionId, 'Same label', 'Pack', '', addonId: 'c' * 64, bingeKey: 'b' * 64)],
          [],
          null,
        ),
      ),
      isNull,
    );
  });

  test('explicit Next is terminal, durable offline and keeps the real early offset and completion date', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = TedLocalStore(db);
    addTearDown(store.close);
    final f = ControlFixture();
    await f.auth.login('https://ted.example', 'fixture', '', 'Offline next');
    f.rejectReports = true;
    const media = TedMediaIdentity('episode', 'tt1234567:1:2');
    final playback = TedPlayback(
      TedClient(f.auth),
      f.player,
      const TedPlaybackSession(sessionId, media, '/device/file', 100000, 10000),
      journal: store,
      offline: true,
    );
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await playback.open();
          await f.loaded();
          await playback.seek(const Duration(seconds: 7));
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 7.0});
          await Future<void>.delayed(Duration.zero);
          await playback.stop(markWatched: true);
          await playback.stop();
          final event = await store.lastPosition(tedOfflineScope(f.auth)!, media);
          expect(event!['kind'], 'complete');
          expect(event['position_ms'], 7000);
          expect(event['natural_eof'], false);
          expect(await store.pending(tedOfflineScope(f.auth)!), 4);
          await store.recoverInterrupted();
          expect((await store.lastPosition(tedOfflineScope(f.auth)!, media))!['kind'], 'complete');
          final watch = const TedDownloadWatch(media, false, false, 0, 100000, null, null).withLocal(event, 100000);
          expect(watch.played, true);
          expect(watch.inProgress, false);
          expect(watch.completedAt, DateTime.parse(event['observed_at'] as String));
        } finally {
          await playback.closePlayer();
          f.auth.close();
        }
      },
    );
  });

  test('offline episode buttons use only completed verified local copies in tuple order', () async {
    final root = await Directory.systemTemp.createTemp('ted-offline-next-');
    addTearDown(() => root.delete(recursive: true));
    final store = TedLocalStore(AppDatabase.forTesting(NativeDatabase.memory()));
    addTearDown(store.close);
    var requests = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((request) async {
        requests++;
        return response(pair(DateTime.now()));
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Offline neighbors');
    final manager = TedDownloads(TedClient(auth), store, root);
    addTearDown(manager.dispose);
    final scope = tedOfflineScope(auth)!;
    for (final (index, id) in [
      'tt1234567:1:1',
      'tt1234567:1:3',
      'tt1234567:2:1',
      'tt1234567:2:2',
      'tt1234567:0:1',
    ].indexed) {
      final value = file(scope, index + 1, TedMediaIdentity('episode', id), 'Episode');
      await store.saveDownload(scope, value);
      await manager.directory(value['id'] as String).create();
      if (index != 3) {
        await File(
          '${manager.directory(value['id'] as String).path}/media.bin',
        ).writeAsBytes(List.filled(value['bytes'] as int, 0));
      }
    }
    final before = requests;
    final targets = await manager.offlineTargets(const TedMediaIdentity('episode', 'tt1234567:1:3'));
    expect(targets.previous!.media.id, 'tt1234567:1:1');
    expect(targets.next!.media.id, 'tt1234567:2:1');
    expect((await manager.offlineTargets(targets.next!.media)).next, isNull);
    expect(requests, before);
  });
}
