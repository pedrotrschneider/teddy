import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:logger/logger.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_log_uploader.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/utils/app_logger.dart';
import '../test_helpers/prefs.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late TedLocalStore store;
  late SettingsService settings;
  DateTime now = DateTime.utc(2026, 11, 25);
  Future<TedAuth> login() async {
    final a = TedAuth(store: MemoryStore(), now: () => now, client: MockClient((r) async => response(pair(now))));
    await a.login('https://ted.example', 'viewer', '', 'fixture');
    return a;
  }

  LogEntry entry(String message) => LogEntry(timestamp: now, level: Level.warning, message: message);
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = TedLocalStore(db);
    now = DateTime.utc(2026, 11, 25);
  });
  tearDown(() async {
    await store.close();
  });
  test('lost acknowledgments keep exact redacted batches across restart', () async {
    final auth = await login();
    final sent = <Map<String, dynamic>>[];
    var reject = true;
    Future<Map<String, dynamic>> send(TedAuth a, Map<String, dynamic> data, Future<void> abort) async {
      sent.add(data);
      if (reject) throw const TedFailure('unavailable');
      return {'accepted': true, 'batch_id': data['batch_id']};
    }

    var uploader = TedLogUploader(
      store: store,
      auth: () => auth,
      active: () => true,
      settings: settings,
      now: () => now,
      interval: const Duration(days: 1),
      send: send,
    );
    uploader.resume();
    uploader.capture(
      entry(
        'TED playback: session=33333333-3333-4333-8333-333333333333 timeout https://private.invalid/media?token=secret Authorization: Bearer super-secret',
      ),
    );
    await uploader.flush();
    expect(sent, hasLength(1));
    expect(jsonEncode(sent.single), isNot(contains('private.invalid')));
    expect(jsonEncode(sent.single), isNot(contains('super-secret')));
    final original = jsonEncode(sent.single);
    await uploader.close();
    reject = false;
    now = now.add(const Duration(minutes: 1));
    uploader = TedLogUploader(
      store: store,
      auth: () => auth,
      active: () => true,
      settings: settings,
      now: () => now,
      interval: const Duration(days: 1),
      send: send,
    );
    uploader.resume();
    await uploader.flush();
    expect(jsonEncode(sent.last), original);
    expect((await db.customSelect('SELECT count(*) n FROM ted_log_batches').getSingle()).read<int>('n'), 0);
    await uploader.close();
    auth.close();
  });
  test('opt-out cancels held uploads and purges only diagnostic queues', () async {
    final auth = await login(), entered = Completer<void>(), held = Completer<Map<String, dynamic>>();
    var sends = 0;
    await db.customStatement("INSERT INTO ted_installation(key,value) VALUES('retained','identity')");
    final uploader = TedLogUploader(
      store: store,
      auth: () => auth,
      active: () => true,
      settings: settings,
      interval: const Duration(days: 1),
      send: (a, b, abort) async {
        sends++;
        entered.complete();
        return Future.any([held.future, abort.then<Map<String, dynamic>>((_) => throw const TedFailure('cancelled'))]);
      },
    );
    uploader.resume();
    uploader.capture(entry('TED download: phase=failed'));
    final uploading = uploader.flush();
    await entered.future;
    await settings.write(SettingsService.sendDiagnosticLogs, false);
    await uploading;
    await uploader.flush();
    uploader.capture(entry('must not be sent'));
    await uploader.flush();
    expect(sends, 1);
    expect((await db.customSelect('SELECT count(*) n FROM ted_log_batches').getSingle()).read<int>('n'), 0);
    expect(
      (await db.customSelect("SELECT value FROM ted_installation WHERE key='retained'").getSingle()).read<String>(
        'value',
      ),
      'identity',
    );
    await uploader.close();
    auth.close();
  });
  test('profile fencing rejects late acknowledgments and never uploads another scope', () async {
    final a = await login(), b = await login();
    await b.logout();
    await b.login('https://other.example', 'other', '', 'fixture');
    var current = a;
    final entered = Completer<void>(), held = Completer<Map<String, dynamic>>();
    final owners = <TedAuth>[];
    final uploader = TedLogUploader(
      store: store,
      auth: () => current,
      active: () => true,
      settings: settings,
      interval: const Duration(days: 1),
      send: (owner, data, abort) async {
        owners.add(owner);
        if (identical(owner, a)) {
          entered.complete();
          return held.future;
        }
        return {'accepted': true, 'batch_id': data['batch_id']};
      },
    );
    uploader.resume();
    uploader.capture(entry('old profile'));
    final uploading = uploader.flush();
    await entered.future;
    uploader.capture(entry('old pending profile'));
    current = b;
    uploader.resume();
    held.complete({'accepted': true, 'batch_id': 'incorrect'});
    await uploading;
    uploader.capture(entry('new profile'));
    await uploader.flush();
    expect(owners, [a, b]);
    final rows = await db.customSelect('SELECT scope,payload FROM ted_log_batches').get();
    expect(rows, hasLength(2));
    expect(rows.every((row) => row.read<String>('scope') == tedOfflineScope(a)), true);
    expect(rows.any((row) => row.read<String>('payload').contains('old pending profile')), true);
    await uploader.close();
    a.close();
    b.close();
  });
  test('expiry and a corrupt queued batch do not block fresh diagnostics', () async {
    final auth = await login();
    final scope = tedOfflineScope(auth)!;
    for (final item in [
      ['expired', now.subtract(const Duration(days: 8)).millisecondsSinceEpoch],
      ['corrupt', now.millisecondsSinceEpoch],
    ]) {
      await db.customStatement('INSERT INTO ted_log_batches VALUES(?,?,?,?,?)', [
        item[0],
        scope,
        '{invalid',
        item[1],
        8,
      ]);
    }
    final sent = <Map<String, dynamic>>[];
    final uploader = TedLogUploader(
      store: store,
      auth: () => auth,
      active: () => true,
      settings: settings,
      now: () => now,
      interval: const Duration(days: 1),
      send: (_, batch, _) async {
        sent.add(batch);
        return {'accepted': true, 'batch_id': batch['batch_id']};
      },
    );
    uploader.resume();
    uploader.capture(entry('fresh diagnostic'));
    await uploader.flush();
    expect(sent, hasLength(1));
    expect(jsonEncode(sent.single), contains('fresh diagnostic'));
    expect((await db.customSelect('SELECT count(*) n FROM ted_log_batches').getSingle()).read<int>('n'), 0);
    await uploader.close();
    auth.close();
  });
  test('schema 33 upgrade adds diagnostics while retaining device reports and downloads', () async {
    final directory = await Directory.systemTemp.createTemp('teddy-logs-migration-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/legacy.sqlite');
    var old = AppDatabase.forTesting(NativeDatabase(file));
    await old.customStatement("INSERT INTO ted_installation VALUES('device_id','retained-device')");
    await old.customStatement("INSERT INTO ted_sessions(id,scope,media) VALUES('session','account','media')");
    await old.customStatement("INSERT INTO ted_reports(id,session_id,envelope) VALUES('report','session','immutable')");
    await old.customStatement("INSERT INTO ted_downloads VALUES('download','account','media','owned')");
    await old.customStatement('DROP TABLE ted_log_batches');
    await old.customStatement('PRAGMA user_version=33');
    await old.close();
    old = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(old.close);
    await old.customStatement("INSERT INTO ted_log_batches VALUES('batch','account','{}',1,2)");
    expect((await old.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 34);
    expect(
      (await old.customSelect('SELECT envelope FROM ted_reports').getSingle()).read<String>('envelope'),
      'immutable',
    );
    expect(
      (await old.customSelect('SELECT value FROM ted_installation').getSingle()).read<String>('value'),
      'retained-device',
    );
    expect((await old.customSelect('SELECT value FROM ted_downloads').getSingle()).read<String>('value'), 'owned');
  });
  test('log compression reuses the ordinary authentication owner', () async {
    Map<String, dynamic>? body;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        expect(request.headers['content-encoding'], 'gzip');
        body = jsonDecode(utf8.decode(gzip.decode(request.bodyBytes))) as Map<String, dynamic>;
        return response({'accepted': true, 'batch_id': body!['batch_id']});
      }),
    );
    await auth.login('https://ted.example', 'viewer', '', 'fixture');
    final ack = await auth.uploadLogs({'batch_id': 'exact-batch', 'entries': []});
    expect(ack['accepted'], true);
    expect(body!['batch_id'], 'exact-batch');
    auth.close();
  });
}
