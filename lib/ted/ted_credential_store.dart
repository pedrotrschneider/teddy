import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'ted_models.dart';

abstract interface class TedCredentialStore {
  Future<TedCredentials?> read();
  Future<void> save(TedCredentials credentials);
  Future<void> clear();
}

/// Kept separate from Plezy's preference vault: that vault's obfuscation key
/// lives beside its data. Native TED tokens must use platform secure storage.
class TedSecureCredentialStore implements TedCredentialStore {
  final FlutterSecureStorage storage;
  final Duration operationTimeout;
  Future<void> _tail = Future<void>.value();
  static const _key = 'teddy.ted.credentials.v1';

  TedSecureCredentialStore({FlutterSecureStorage? storage, this.operationTimeout = const Duration(seconds: 10)})
    : storage =
          storage ??
          const FlutterSecureStorage(
            // Private macOS builds can use the login Keychain without a team/app
            // group provisioning profile. The key never leaves OS-backed storage.
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final actual = _tail.then((_) => operation());
    _tail = actual.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    // A timeout is not rollback of an OS write. _tail still waits for the actual
    // operation; later sign-ins/deletes cannot race a late write/read-back.
    return actual.timeout(operationTimeout).onError((_, _) => throw const TedFailure('storage_unavailable'));
  }

  @override
  Future<TedCredentials?> read() => _serialized(() async {
    final raw = await storage.read(key: _key);
    return raw == null ? null : TedCredentials.decode(raw);
  });

  @override
  Future<void> save(TedCredentials credentials) => _serialized(() async {
    final raw = credentials.encode();
    await storage.write(key: _key, value: raw);
    if (await storage.read(key: _key) != raw) throw const TedFailure('storage_unavailable');
  });

  @override
  Future<void> clear() => _serialized(() async {
    await storage.delete(key: _key);
    if (await storage.read(key: _key) != null) throw const TedFailure('storage_unavailable');
  });
}
