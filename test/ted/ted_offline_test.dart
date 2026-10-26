import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;

const media = TedMediaIdentity('movie', 'tt1234567');
const viewing = TedPlaybackSession(
  '33333333-3333-4333-8333-333333333333',
  media,
  'local-file',
  100000,
  7000,
  watchRevision: 3,
);
Map<String, dynamic> event(int seq, {String kind = 'progress'}) => {
  'id': '99999999-9999-4999-8999-${seq.toString().padLeft(12, '0')}',
  'session_id': viewing.id,
  'media': media.toJson(),
  'sequence': seq,
  'kind': kind,
  'position_ms': 21000,
  'duration_ms': 100000,
  'observed_at': '2026-10-10T12:00:00.000Z',
  'origin': 'offline',
  'natural_eof': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('brief offline viewing retains receipts but no resume until 5 percent, including after restart', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    var store = TedLocalStore(db);
    await store.record('scope', viewing, {...event(1, kind: 'start'), 'position_ms': 0}, offline: true);
    await store.record('scope', viewing, {...event(2), 'position_ms': 4999}, offline: true);
    expect(await store.lastPosition('scope', media), isNull);
    expect(await store.pending('scope'), 2);
    store = TedLocalStore(db);
    await store.record('scope', viewing, {...event(3), 'position_ms': 5000}, offline: true);
    expect((await store.lastPosition('scope', media))!['position_ms'], 5000);
    await store.record('scope', viewing, {...event(4, kind: 'stop'), 'position_ms': 1000}, offline: true);
    expect((await store.lastPosition('scope', media))!['position_ms'], 1000);
    expect(await store.lastPosition('other', media), isNull);
  });
  test('uncertain refresh restores only offline identity; sign-out markers hide device files', () async {
    final saved = MemoryStore();
    final time = DateTime.utc(2026, 10, 10);
    final tokens = TedTokens.fromJson(pair(time));
    await saved.save(
      TedCredentials(
        Uri.parse('https://ted.example/'),
        '11111111-1111-4111-8111-111111111111',
        tokens,
        refreshPending: true,
      ),
    );
    var requests = 0;
    final auth = TedAuth(
      store: saved,
      now: () => time,
      client: MockClient((_) async {
        requests++;
        return response({});
      }),
    );
    addTearDown(auth.close);
    await expectLater(auth.restore(), throwsA(isA<TedFailure>()));
    expect(auth.signedIn, false);
    expect(tedOfflineScope(auth), isNotNull);
    await expectLater(auth.headers(), throwsA(isA<TedFailure>()));
    expect(requests, 0);
    final marker = TedCredentials.decode(
      TedCredentials(
        saved.saved!.server,
        saved.saved!.deviceId,
        tokens,
        refreshPending: true,
        offlineAllowed: false,
      ).encode(),
    );
    await saved.save(marker);
    await expectLater(auth.restore(), throwsA(isA<TedFailure>()));
    expect(tedOfflineScope(auth), isNull);
  });
  test('offline source provenance is durably replayed without playback URLs', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = TedLocalStore(db);
    addTearDown(db.close);
    const prepared = '44444444-4444-4444-8444-444444444444';
    final session = TedPlaybackSession(
      viewing.id,
      media,
      '/private/offline/file',
      100000,
      7000,
      watchRevision: 3,
      downloadSourceSession: prepared,
    );
    final sent = <Map<String, dynamic>>[];
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(DateTime.now()));
        final value = jsonDecode(request.body) as Map<String, dynamic>;
        sent.add(value);
        return response({'code': 'unavailable'}, 503);
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final scope = tedOfflineScope(auth)!;
    await store.record(scope, session, event(1, kind: 'start'), offline: true);
    for (var i = 0; i < 2; i++) {
      await expectLater(store.flush(TedClient(auth), scope), throwsA(isA<TedFailure>()));
    }
    expect(sent[0], sent[1]);
    expect((sent.first['sessions'] as List).single['source_session'], prepared);
    expect(jsonEncode(sent), isNot(contains('/private/offline/file')));
    expect(await store.pending(scope), 1);
  });
  test('lost and partial receipts retain exact ordered reports, scoped to account/device', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = TedLocalStore(db);
    addTearDown(db.close);
    final sent = <List<dynamic>>[];
    var mode = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(DateTime.now()));
        final input = jsonDecode(request.body) as Map;
        sent.add(input['events'] as List);
        final registrations = input['sessions'] as List;
        expect(registrations.single['started_at'], event(1)['observed_at']);
        expect(registrations.single['watch_revision'], 3);
        if (mode == 0) return response({'error': 'unavailable'}, 503);
        final events = input['events'] as List;
        return response({
          'events': [
            for (final e in mode == 1 ? events.take(1) : events)
              {'id': e['id'], 'outcome': 'applied', 'duplicate': true},
          ],
        });
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = TedClient(auth), scope = tedOfflineScope(auth)!;
    await store.record(scope, viewing, event(1, kind: 'start'), offline: true);
    await store.record(scope, viewing, event(2, kind: 'stop'), offline: true);
    await expectLater(store.flush(client, scope), throwsA(isA<TedFailure>()));
    expect(await store.pending(scope), 2);
    mode = 1;
    await expectLater(store.flush(client, scope), throwsA(isA<TedFailure>()));
    expect(await store.pending(scope), 2);
    mode = 2;
    await store.flush(client, scope);
    expect(await store.pending(scope), 0);
    expect(sent[0], sent[1]);
    expect(sent[1], sent[2]);
    await expectLater(store.flush(client, 'another-account'), throwsA(isA<TedFailure>()));
  });

  test('file database reopens and closes interrupted viewing at last saved position without EOF', () async {
    final temp = await Directory.systemTemp.createTemp('teddy-journal-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/offline.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    var store = TedLocalStore(db);
    final device = await store.installationDevice();
    await store.record('device-account', viewing, event(1, kind: 'start'), offline: true);
    await store.record('device-account', viewing, event(2), offline: true);
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    store = TedLocalStore(db);
    addTearDown(db.close);
    expect(await store.installationDevice(), device);
    await store.recoverInterrupted();
    await store.recoverInterrupted();
    expect(await store.pending('device-account'), 3);
    final last = await store.lastPosition('device-account', media);
    expect(last!['sequence'], 3);
    expect(last['kind'], 'stop');
    expect(last['position_ms'], 21000);
    expect(last['observed_at'], event(2)['observed_at']);
    expect(last['natural_eof'], false);
  });

  test('more than one hundred disconnected reports remain durable and replay in bounded batches', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = TedLocalStore(db);
    addTearDown(db.close);
    final seq = <int>[];
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(DateTime.now()));
        final events = (jsonDecode(request.body)['events'] as List).cast<Map>();
        expect(events.length, lessThanOrEqualTo(20));
        seq.addAll(events.map((e) => e['sequence'] as int));
        return response({
          'events': [
            for (final e in events) {'id': e['id'], 'outcome': 'applied'},
          ],
        });
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final scope = tedOfflineScope(auth)!;
    for (var i = 1; i <= 121; i++) {
      await store.record(
        scope,
        viewing,
        event(
          i,
          kind: i == 1
              ? 'start'
              : i == 121
              ? 'stop'
              : 'progress',
        ),
        offline: true,
      );
    }
    expect(await store.pending(scope), 121);
    await store.flush(TedClient(auth), scope);
    expect(seq, List.generate(121, (i) => i + 1));
    expect(await store.pending(scope), 0);
  });
}
