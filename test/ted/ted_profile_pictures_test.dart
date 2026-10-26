import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_profile_pictures.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;

Future<Uint8List> picture() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffccaa33), ui.BlendMode.src);
  final drawing = recorder.endRecording();
  final image = await drawing.toImage(256, 256);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  image.dispose();
  drawing.dispose();
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('pictures survive restart, stay account scoped, and refresh failures retain the last good image', () async {
    final dir = await Directory.systemTemp.createTemp('ted-profile-pictures');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/device.db');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    var store = TedLocalStore(db);
    var pictures = TedProfilePictures(store);
    final now = DateTime.utc(2026, 10, 16);
    var status = 200, calls = 0;
    var malformed = false;
    final bytes = await picture();
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return response(pair(now));
        expect(r.url.path, '/api/client/v1/account/avatar');
        expect(r.headers['Authorization'], startsWith('Bearer ted_a_'));
        expect(r.url.queryParameters, isEmpty);
        calls++;
        return http.Response.bytes(
          status == 200 ? (malformed ? Uint8List.fromList([1, 2, 3]) : bytes) : [],
          status,
          headers: {'x-ted-compatibility-version': '0.3'},
        );
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Picture');
    final scope = tedOfflineScope(auth)!;
    await pictures.refresh(auth, current: () => true);
    expect(pictures[scope], bytes);
    pictures.dispose();
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    store = TedLocalStore(db);
    pictures = TedProfilePictures(store);
    addTearDown(pictures.dispose);
    addTearDown(db.close);
    await pictures.load([scope, 'another-account']);
    expect(calls, 1); // Loading the chooser never authenticates inactive profiles.
    expect(pictures[scope], bytes);
    expect(pictures['another-account'], isNull);
    final cached = pictures[scope];
    await pictures.refresh(auth, current: () => true, force: true);
    expect(identical(pictures[scope], cached), true, reason: 'unchanged pictures keep the same ImageCache key');
    status = 404; // An older server is a failure, not successful absence.
    await pictures.refresh(auth, current: () => true, force: true);
    expect(pictures[scope], bytes);
    status = 200;
    malformed = true;
    await pictures.refresh(auth, current: () => true, force: true);
    expect(pictures[scope], bytes);
    status = 204;
    await pictures.refresh(auth, current: () => true, force: true);
    expect(pictures[scope], isNull);
    expect(await store.profilePicture(scope), isNull);
  });

  test('a delayed outgoing response cannot recreate a signed-out cache or overwrite a newer response', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TedLocalStore(db);
    final pictures = TedProfilePictures(store);
    addTearDown(pictures.dispose);
    final pending = <Completer<http.Response>>[];
    final now = DateTime.utc(2026, 10, 16);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) return response(pair(now));
        final request = Completer<http.Response>();
        pending.add(request);
        return request.future;
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Picture');
    final scope = tedOfflineScope(auth)!;
    final bytes = await picture();
    var active = true;
    final outgoing = pictures.refresh(auth, current: () => active);
    while (pending.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    active = false;
    await store.purgeProfile(scope);
    pending.removeAt(0).complete(http.Response.bytes(bytes, 200));
    await outgoing;
    expect(await store.profilePicture(scope), isNull);
    expect(pictures[scope], isNull);

    active = true;
    final old = pictures.refresh(auth, current: () => active, force: true);
    while (pending.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final latest = pictures.refresh(auth, current: () => active, force: true);
    while (pending.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    pending[1].complete(http.Response('', 204, headers: {'x-ted-compatibility-version': '0.3'}));
    await latest;
    pending[0].complete(http.Response.bytes(bytes, 200));
    await old;
    expect(await store.profilePicture(scope), isNull);
  });

  test('v31 upgrade preserves reports and downloads; sign out purges only its own picture', () async {
    final dir = await Directory.systemTemp.createTemp('ted-profile-picture-upgrade');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/device.db');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    await db.customStatement("INSERT INTO ted_downloads VALUES('copy','owner','movie','owned')");
    await db.customStatement("INSERT INTO ted_sessions(id,scope,media) VALUES('s','owner','movie')");
    await db.customStatement("INSERT INTO ted_reports(id,session_id,envelope) VALUES('e','s','immutable')");
    await db.customStatement('DROP TABLE ted_profile_pictures');
    await db.customStatement('PRAGMA user_version=31');
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    expect(
      (await db.customSelect('SELECT envelope FROM ted_reports').getSingle()).read<String>('envelope'),
      'immutable',
    );
    expect((await db.customSelect('SELECT value FROM ted_downloads').getSingle()).read<String>('value'), 'owned');
    final store = TedLocalStore(db);
    final bytes = await picture();
    await store.saveProfilePicture('a', bytes, valid: () => true);
    await store.saveProfilePicture('b', bytes, valid: () => true);
    await store.purgeProfile('a');
    await store.saveProfilePicture('a', bytes, valid: () => false);
    expect(await store.profilePicture('a'), isNull);
    expect(await store.profilePicture('b'), bytes);
  });
}
