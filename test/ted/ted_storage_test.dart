import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:plezy/ted/ted_credential_store.dart';
import 'package:plezy/ted/ted_models.dart';
import 'ted_auth_test.dart' show pair;

class HeldStorage extends FlutterSecureStorage {
  String? value;
  final entered = Completer<void>();
  final release = Completer<void>();
  int writes = 0;
  bool corrupt = false;
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    if (writes == 1) {
      entered.complete();
      await release.future;
    }
    this.value = corrupt ? 'malformed' : value;
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => value;
  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    value = null;
  }
}

void main() {
  test('a timed-out OS write finishes before the next credential save', () async {
    final platform = HeldStorage();
    final store = TedSecureCredentialStore(storage: platform, operationTimeout: const Duration(milliseconds: 20));
    final now = DateTime.utc(2026, 10, 10);
    final old = TedCredentials(
      Uri.parse('https://ted.example/'),
      '11111111-1111-4111-8111-111111111111',
      TedTokens.fromJson(pair(now)),
    );
    final next = TedCredentials(old.server, old.deviceId, TedTokens.fromJson(pair(now, suffix: 'b')));
    final first = store.save(old);
    final failed = expectLater(first, throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'storage_unavailable')));
    await platform.entered.future;
    await failed;
    final second = store.save(next);
    // Waiters cannot publish another credential while the OS operation still
    // owns the store. The held native future defines this ordering.
    expect(platform.writes, 1);
    platform.release.complete();
    await second;
    expect((await store.read())!.tokens.refresh, next.tokens.refresh);
    expect(platform.writes, 2);
  });

  test('read-back mismatch fails instead of publishing a saved token pair', () async {
    final platform = HeldStorage()..corrupt = true;
    platform.release.complete();
    final store = TedSecureCredentialStore(storage: platform);
    final value = TedCredentials(
      Uri.parse('https://ted.example/'),
      '11111111-1111-4111-8111-111111111111',
      TedTokens.fromJson(pair(DateTime.utc(2026, 10, 10))),
    );
    await expectLater(
      store.save(value),
      throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'storage_unavailable')),
    );
    await expectLater(store.read(), throwsA(isA<TedFailure>()));
  });
}
