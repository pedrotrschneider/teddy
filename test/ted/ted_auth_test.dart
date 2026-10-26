import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_credential_store.dart';
import 'package:plezy/ted/ted_models.dart';

const family = '11111111-1111-4111-8111-111111111111';
Map<String, dynamic> pair(DateTime now, {String suffix = 'a', String familyId = family, int userId = 1}) => {
  'token_type': 'Bearer',
  'access_token': 'ted_a_${suffix * 43}',
  'refresh_token': 'ted_r_${suffix * 43}',
  'family_id': familyId,
  'expires_in': 600,
  'access_expires_at': now.add(const Duration(minutes: 10)).toIso8601String(),
  'refresh_expires_at': DateTime.utc(2026, 10, 30).toIso8601String(),
  'family_expires_at': DateTime.utc(2026, 12, 30).toIso8601String(),
  'user': {'id': userId, 'display_name': 'Fixture'},
};

class MemoryStore implements TedCredentialStore {
  TedCredentials? saved;
  bool failReady = false;
  final states = <bool>[];
  @override
  Future<TedCredentials?> read() async => saved;
  @override
  Future<void> clear() async {
    saved = null;
  }

  @override
  Future<void> save(TedCredentials value) async {
    saved = value;
    states.add(value.refreshPending);
    if (failReady && !value.refreshPending) throw const TedFailure('storage_unavailable');
  }
}

http.Response response(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'x-ted-compatibility-version': '0.3'});
final signInRequired = throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'sign_in_required'));

void main() {
  test('successful HTTP response from another contract cannot create a profile', () async {
    final store = MemoryStore();
    final auth = TedAuth(
      store: store,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(pair(DateTime.utc(2026, 10, 10))),
          200,
          headers: {'x-ted-compatibility-version': '2'},
        ),
      ),
    );
    addTearDown(auth.close);
    await expectLater(
      auth.login('https://ted.example', 'fixture', '', 'test'),
      throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'incompatible_version')),
    );
    expect(store.saved, isNull);
    expect(auth.compatibilityIssue.value?.server, Uri.parse('https://ted.example/'));
    expect(auth.compatibilityIssue.value?.requiredVersion.toString(), '2');
  });

  test('major mismatch rejects login without saving credentials', () async {
    final store = MemoryStore();
    final auth = TedAuth(
      store: store,
      client: MockClient((request) async {
        expect(request.headers['X-Teddy-Compatibility-Major'], '0');
        return response({'code': 'incompatible_version'}, 426);
      }),
    );
    addTearDown(auth.close);
    await expectLater(
      auth.login('https://ted.example', 'fixture', '', 'test'),
      throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'incompatible_version')),
    );
    expect(store.saved, isNull);
    expect(auth.signedIn, isFalse);
  });

  test('refresh incompatibility retains its update target and uncertain-rotation tombstone', () async {
    var now = DateTime.utc(2026, 10, 10);
    final store = MemoryStore();
    final auth = TedAuth(
      store: store,
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        expect(request.url.path.endsWith('/refresh'), true);
        expect(store.saved!.refreshPending, true);
        return http.Response('{"code":"incompatible_version"}', 426, headers: {'x-ted-compatibility-version': '0.4'});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    now = now.add(const Duration(minutes: 11));
    await expectLater(auth.headers(), signInRequired);
    expect(auth.compatibilityIssue.value?.requiredVersion.toString(), '0.4');
    expect(store.saved!.refreshPending, true);
    expect(store.saved!.offlineAllowed, true);
    expect(auth.signedIn, false);
  });

  test('late incompatible response from a closed connection cannot open an update prompt', () async {
    final entered = Completer<void>();
    final reply = Completer<http.Response>();
    final auth = TedAuth(
      store: MemoryStore(),
      client: MockClient((_) {
        entered.complete();
        return reply.future;
      }),
    );
    var notifications = 0;
    auth.compatibilityIssue.addListener(() => notifications++);
    final pending = expectLater(auth.login('https://ted.example', 'fixture', '', 'test'), signInRequired);
    await entered.future;
    auth.close();
    reply.complete(
      http.Response('{"code":"incompatible_version"}', 426, headers: {'x-ted-compatibility-version': '0.4'}),
    );
    await pending;
    expect(notifications, 0);
    expect(auth.compatibilityIssue.value, isNull);
    auth.close();
  });

  test('waiting requests rotate once and save the whole replacement before using it', () async {
    var now = DateTime.utc(2026, 10, 10);
    final store = MemoryStore();
    final entered = Completer<void>();
    final release = Completer<void>();
    var rotations = 0;
    final auth = TedAuth(
      store: store,
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        if (request.url.path.endsWith('/refresh')) {
          expect(request.headers.containsKey('Authorization'), false);
          expect(jsonDecode(request.body), {'refresh_token': 'ted_r_${'a' * 43}'});
          expect(store.saved!.refreshPending, true);
          rotations++;
          entered.complete();
          await release.future;
          return response(pair(now, suffix: 'b'));
        }
        expect(request.headers['Authorization'], 'Bearer ted_a_${'b' * 43}');
        expect(store.saved!.refreshPending, false);
        expect(store.saved!.tokens.familyId, family);
        return response({'ok': true});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture desktop');
    now = now.add(const Duration(minutes: 11));
    final calls = List.generate(12, (_) => auth.json('GET', '/api/client/v1/auth/me'));
    await entered.future;
    expect(rotations, 1);
    release.complete();
    await Future.wait(calls);
    expect(rotations, 1);
    expect(store.states, [false, true, false]);
  });

  test('lost refresh response is not retried and cannot be restored after restart', () async {
    final now = DateTime.utc(2026, 10, 10);
    final store = MemoryStore();
    var rotations = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/login')) return response(pair(now));
      rotations++;
      throw http.ClientException('secret must not appear');
    });
    final auth = TedAuth(store: store, now: () => now, client: client);
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture');
    await expectLater(auth.refresh(), signInRequired);
    await expectLater(auth.headers(), signInRequired);
    expect(rotations, 1);
    expect(store.saved!.refreshPending, true);
    final restarted = TedAuth(store: store, now: () => now);
    addTearDown(restarted.close);
    await expectLater(restarted.restore(), signInRequired);
  });

  test('successful rotation with uncertain OS save requires sign-in', () async {
    final now = DateTime.utc(2026, 10, 10);
    final store = MemoryStore();
    final auth = TedAuth(
      store: store,
      now: () => now,
      client: MockClient(
        (request) async => response(pair(now, suffix: request.url.path.endsWith('/login') ? 'a' : 'b')),
      ),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture');
    store.failReady = true;
    await expectLater(auth.refresh(), signInRequired);
    expect(store.saved!.refreshPending, true);
    expect(auth.signedIn, false);
  });

  test('unexpected family/account during refresh fails closed', () async {
    final now = DateTime.utc(2026, 10, 10);
    for (final changed in [
      pair(now, suffix: 'b', familyId: '22222222-2222-4222-8222-222222222222'),
      pair(now, suffix: 'b', userId: 2),
    ]) {
      final store = MemoryStore();
      final auth = TedAuth(
        store: store,
        now: () => now,
        client: MockClient((request) async => response(request.url.path.endsWith('/login') ? pair(now) : changed)),
      );
      addTearDown(auth.close);
      await auth.login('https://ted.example', 'fixture', '', 'Fixture');
      await expectLater(auth.refresh(), signInRequired);
      expect(store.saved!.refreshPending, true);
    }
  });

  test('401 retries once with a rotated header and preserves the exact report body', () async {
    final now = DateTime.utc(2026, 10, 10);
    final seen = <String>[];
    var reportCalls = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        if (request.url.path.endsWith('/refresh')) return response(pair(now, suffix: 'b'));
        seen.add(request.body);
        reportCalls++;
        if (reportCalls == 1) return response({}, 401);
        expect(request.headers['Authorization'], 'Bearer ted_a_${'b' * 43}');
        return response({'ok': true});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture');
    await auth.json(
      'POST',
      '/api/client/v1/playback/events',
      body: {
        'events': [
          {'id': 'stable-event'},
        ],
      },
    );
    expect(reportCalls, 2);
    expect(seen[0], seen[1]);
  });

  test('account switch during an old response never sends new credentials to the old host', () async {
    final now = DateTime.utc(2026, 10, 10);
    final entered = Completer<void>();
    final release = Completer<void>();
    var oldCalls = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return response(pair(now, suffix: request.url.host == 'old.example' ? 'a' : 'b'));
        }
        oldCalls++;
        expect(request.url.host, 'old.example');
        expect(request.headers['Authorization'], 'Bearer ted_a_${'a' * 43}');
        entered.complete();
        await release.future;
        return response({}, 401);
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://old.example', 'fixture', '', 'Fixture');
    final pending = auth.json('GET', '/api/client/v1/auth/me');
    final failure = expectLater(pending, signInRequired);
    await entered.future;
    await auth.login('https://new.example', 'fixture', '', 'Fixture');
    release.complete();
    await failure;
    expect(oldCalls, 1);
    expect(auth.server!.host, 'new.example');
  });

  test('credential URLs, redirects and malformed sessions are refused without exposing secrets', () async {
    expect(() => tedServerUri('https://user:password@ted.example'), throwsA(isA<TedFailure>()));
    expect(() => tedServerUri('https://ted.example/?token=secret'), throwsA(isA<TedFailure>()));
    final now = DateTime.utc(2026, 10, 10);
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        expect(request.followRedirects, false);
        return http.Response('', 302, headers: {'location': 'https://other.example/secret'});
      }),
    );
    addTearDown(auth.close);
    await expectLater(auth.login('https://ted.example', 'fixture', 'secret', 'Fixture'), throwsA(isA<TedFailure>()));
    expect(TedTokens.fromJson(pair(now)).toString(), 'TedTokens(redacted)');
    expect(
      () => TedPlaybackSession.fromJson({
        'id': family,
        'media': {'kind': 'movie', 'id': 'tt1234567'},
        'media_url': 'https://provider.example/secret',
        'duration_ms': 100000,
        'resume_ms': 0,
      }, const TedMediaIdentity('movie', 'tt1234567')),
      throwsA(isA<TedFailure>()),
    );
  });
}
