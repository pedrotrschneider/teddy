import 'dart:io';
import 'package:plezy/ted/ted_downloads.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_profiles.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'ted_auth_test.dart' show pair, response, MemoryStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final values = <String, String>{};
  Completer<void>? hold;
  bool denyReads = false;
  bool denyDeletes = false;
  int deletes = 0;
  int reads = 0;
  setUp(() {
    values.clear();
    hold = null;
    denyReads = false;
    denyDeletes = false;
    deletes = 0;
    reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final key = call.arguments['key'] as String;
      switch (call.method) {
        case 'read':
          reads++;
          if (denyReads) throw PlatformException(code: '-128', message: 'User cancelled Keychain access');
          return values[key];
        case 'write':
          await hold?.future;
          values[key] = call.arguments['value'] as String;
          return null;
        case 'delete':
          deletes++;
          if (denyDeletes) throw PlatformException(code: 'Unexpected security result code', details: -128);
          // Darwin 0.3.2 tries a synchronizable delete as well as the legacy
          // login Keychain. An absent key can fail with missing entitlement.
          if (!values.containsKey(key)) {
            throw PlatformException(code: 'Unexpected security result code', details: -34018);
          }
          values.remove(key);
          return null;
        default:
          throw MissingPluginException();
      }
    });
  });
  TedCredentials credentials(int id, [String server = 'https://ted.example']) => TedCredentials(
    tedServerUri(server),
    '11111111-1111-4111-8111-111111111111',
    TedTokens.fromJson(pair(DateTime.utc(2026, 10, 14), userId: id)),
  );
  test('legacy migration and switches preserve separate server/account families', () async {
    final old = credentials(1);
    values[TedProfiles.legacyKey] = old.encode();
    final vault = TedProfiles(storage: const FlutterSecureStorage());
    final migrated = await vault.read();
    expect(migrated.profiles.single.credentials.encode(), old.encode());
    expect(values.containsKey(TedProfiles.legacyKey), false);
    await vault.connection().save(credentials(2));
    await vault.connection().save(credentials(1, 'https://second.example'));
    await vault.activate(tedProfileKey(old));
    expect((await vault.connection().read())!.tokens.userId, 1);
    expect((await vault.read()).profiles.length, 3);
    await vault.activate(null);
    expect(await vault.connection().read(), null);
    expect((await vault.read()).profiles.length, 3);
  });
  test('signout tombstone survives restart until scoped purge completes', () async {
    final vault = TedProfiles(storage: const FlutterSecureStorage());
    final store = vault.connection();
    final a = credentials(1);
    await store.save(a);
    await vault.connection().save(credentials(2));
    await store.save(TedCredentials(a.server, a.deviceId, a.tokens, refreshPending: true, offlineAllowed: false));
    await store.clear();
    final restarted = TedProfiles(storage: const FlutterSecureStorage());
    expect((await restarted.read()).profiles.where((p) => p.purging).single.key, tedProfileKey(a));
    expect(await restarted.connection(tedProfileKey(a)).read(), null);
    await restarted.finishPurge(tedProfileKey(a));
    expect((await restarted.read()).profiles.single.credentials.tokens.userId, 2);
  });
  test('login after access recovery saves and restores without deleting an absent legacy entry', () async {
    final vault = TedProfiles(storage: const FlutterSecureStorage());
    final a = credentials(1);
    await vault.connection().save(TedCredentials(a.server, a.deviceId, a.tokens, refreshPending: true));
    denyReads = true;
    await expectLater(vault.read(), throwsA(isA<TedFailure>()));
    denyReads = false;
    await vault.retryAccess();
    final now = DateTime.utc(2026, 10, 14);
    final auth = TedAuth(
      store: vault.connection(),
      now: () => now,
      client: MockClient((_) async => response(pair(now))),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture desktop');
    expect(auth.signedIn, true);
    expect(vault.accessUnavailable, false);
    expect(deletes, 0);
    final restored = TedAuth(store: vault.connection(), now: () => now);
    addTearDown(restored.close);
    expect(await restored.restore(), true);
  });
  test('a real legacy deletion failure stays visible and retains recoverable credentials', () async {
    final old = credentials(1);
    values[TedProfiles.legacyKey] = old.encode();
    final vault = TedProfiles(storage: const FlutterSecureStorage());
    denyDeletes = true;
    await expectLater(vault.read(), throwsA(isA<TedFailure>()));
    expect(vault.accessUnavailable, true);
    expect(values[TedProfiles.legacyKey], old.encode());
    expect(values.containsKey(TedProfiles.key), true);
    denyDeletes = false;
    await vault.retryAccess();
    await vault.connection().save(old);
    expect(values.containsKey(TedProfiles.legacyKey), false);
    final deleted = deletes;
    await vault.connection().save(old);
    expect(deletes, deleted);
  });
  test('timed out OS write stays serialized ahead of subsequent credential save', () async {
    final vault = TedProfiles(
      storage: const FlutterSecureStorage(),
      operationTimeout: const Duration(milliseconds: 20),
    );
    hold = Completer<void>();
    await expectLater(vault.connection().save(credentials(1)), throwsA(isA<TedFailure>()));
    final next = vault.connection().save(credentials(2));
    hold!.complete();
    await next;
    expect((await vault.read()).profiles.length, 2);
  });
  test('denied access can be retried repeatedly without clearing profiles or refresh markers', () async {
    final vault = TedProfiles(storage: const FlutterSecureStorage());
    final saved = credentials(1);
    await vault.connection().save(TedCredentials(saved.server, saved.deviceId, saved.tokens, refreshPending: true));
    final original = Map<String, String>.from(values);
    denyReads = true;
    await expectLater(vault.read(), throwsA(isA<TedFailure>()));
    expect(vault.accessUnavailable, true);
    final before = reads;
    await expectLater(vault.retryAccess(), throwsA(isA<TedFailure>()));
    expect(reads, before + 1);
    expect(vault.accessUnavailable, true);
    expect(values, original);
    denyReads = false;
    await vault.retryAccess();
    expect(vault.accessUnavailable, false);
    expect(values, original);
    final auth = TedAuth(store: vault.connection());
    addTearDown(auth.close);
    await expectLater(auth.restore(), throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'sign_in_required')));
    expect(auth.signedIn, false, reason: 'access recovery cannot undo an uncertain refresh');
    expect(auth.offlineUserId, saved.tokens.userId);
  });
  test('manual retry waits for an outstanding OS write instead of racing or resetting it', () async {
    final vault = TedProfiles(
      storage: const FlutterSecureStorage(),
      operationTimeout: const Duration(milliseconds: 20),
    );
    hold = Completer<void>();
    await expectLater(vault.connection().save(credentials(1)), throwsA(isA<TedFailure>()));
    final before = reads;
    var finished = false;
    final retry = vault.retryAccess().then((_) => finished = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(finished, false);
    expect(reads, before);
    hold!.complete();
    await retry;
    expect(vault.accessUnavailable, false);
    expect((await vault.read()).profiles.single.credentials.tokens.userId, 1);
  });
  test('retry never replaces malformed saved credentials with an empty bundle', () async {
    values[TedProfiles.key] = '{broken';
    final vault = TedProfiles(storage: const FlutterSecureStorage());
    await expectLater(vault.read(), throwsA(isA<TedFailure>()));
    await expectLater(vault.retryAccess(), throwsA(isA<TedFailure>()));
    expect(vault.accessUnavailable, true);
    expect(values[TedProfiles.key], '{broken');
  });
  test('profile purge removes only selected reports and data; installation survives', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    for (final scope in ['a', 'b']) {
      await db.customStatement('INSERT INTO ted_sessions(id,scope,media) VALUES(?,?,?)', [scope, scope, 'media']);
      await db.customStatement('INSERT INTO ted_reports(id,session_id,envelope) VALUES(?,?,?)', [
        scope,
        scope,
        'immutable',
      ]);
      await db.customStatement('INSERT INTO ted_downloads VALUES(?,?,?,?)', [scope, scope, 'media', 'owned']);
    }
    await db.customStatement("INSERT INTO ted_installation VALUES('device_id','device')");
    await store.purgeProfile('a');
    expect((await db.customSelect('SELECT id FROM ted_reports').getSingle()).read<String>('id'), 'b');
    expect((await db.customSelect('SELECT scope FROM ted_downloads').getSingle()).read<String>('scope'), 'b');
    expect((await db.customSelect('SELECT value FROM ted_installation').getSingle()).read<String>('value'), 'device');
  });
  test('signout deletes owned files but preserves another profile and unrelated files', () async {
    final root = await Directory.systemTemp.createTemp('ted-profile-purge');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final auth = TedAuth(store: MemoryStore());
    addTearDown(auth.close);
    final downloads = TedDownloads(TedClient(auth), store, root, cancelTask: (_) async => true);
    addTearDown(downloads.dispose);
    const first = '11111111-1111-4111-8111-111111111111', second = '22222222-2222-4222-8222-222222222222';
    for (final (id, scope) in [(first, 'a'), (second, 'b')]) {
      await Directory('${root.path}/$id').create();
      await File('${root.path}/$id/media.bin').writeAsString('owned media');
      await store.saveDownload(scope, {
        'id': id,
        'media': {'kind': 'movie', 'id': 'tt1234567'},
        'scope': scope,
      });
    }
    final unrelated = File('${root.path}/personal.txt');
    await unrelated.writeAsString('keep');
    await downloads.purgeProfile('a');
    expect(await Directory('${root.path}/$first').exists(), false);
    expect(await File('${root.path}/$second/media.bin').readAsString(), 'owned media');
    expect(await unrelated.readAsString(), 'keep');
    await downloads.purgeProfile('a');
    expect((await store.downloads('b')).length, 1);
  });
}
