import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../utils/app_logger.dart';
import 'ted_credential_store.dart';
import 'ted_models.dart';

String tedProfileKey(TedCredentials v) => jsonEncode([tedServerUri(v.server.toString()).toString(), v.tokens.userId]);

class TedSavedProfile {
  final String key;
  final TedCredentials credentials;
  final bool purging;
  const TedSavedProfile(this.key, this.credentials, {this.purging = false});
  String get server => credentials.server.toString();
  String get name => credentials.tokens.displayName;
  String get scope => jsonEncode([server, credentials.tokens.userId, credentials.deviceId]);
}

class TedProfileSnapshot {
  final String? active;
  final List<TedSavedProfile> profiles;
  const TedProfileSnapshot(this.active, this.profiles);
}

/// One verified OS-backed bundle, one writer. No inactive profile refreshes.
/// Purge tombstones retain file ownership until scoped cleanup has completed.
class TedProfiles extends ChangeNotifier {
  final FlutterSecureStorage storage;
  final Duration operationTimeout;
  Future<void> _tail = Future.value();
  bool _accessUnavailable = false;
  bool get accessUnavailable => _accessUnavailable;
  static const key = 'teddy.ted.profiles.v1', legacyKey = 'teddy.ted.credentials.v1';
  TedProfiles({FlutterSecureStorage? storage, this.operationTimeout = const Duration(seconds: 10)})
    : storage = storage ?? const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
  Future<T> _serial<T>(Future<T> Function() work, {bool userInitiated = false}) {
    final actual = _tail.then((_) => work());
    _tail = actual.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    // A user-requested retry waits for the OS prompt to be answered/cancelled.
    // Ordinary timeouts still leave actual OS operations serialized on _tail.
    final result = userInitiated ? actual : actual.timeout(operationTimeout);
    return result.onError((error, _) {
      // Platform messages/details may include sensitive data. Record only the
      // exception type and numeric OSStatus, never credential values or keys.
      final status = error is PlatformException && error.details is int ? ' OSStatus=${error.details}' : '';
      appLogger.w('Profile secure-storage operation failed: ${error.runtimeType}$status');
      if (!_accessUnavailable) {
        _accessUnavailable = true;
        notifyListeners();
      }
      throw const TedFailure('storage_unavailable');
    });
  }

  /// Reissue the real credential read (which permits the platform's permission
  /// UI), not a dummy key or credential reset. Verify the saved bundle before
  /// allowing auth restoration; pending refresh/purge markers remain intact.
  Future<void> retryAccess() => _serial(() async {
    await _read();
    _accessUnavailable = false;
    notifyListeners();
  }, userInitiated: true);

  Future<TedProfileSnapshot> _read() async {
    final raw = await storage.read(key: key);
    if (raw == null) {
      final old = await storage.read(key: legacyKey);
      if (old == null) return const TedProfileSnapshot(null, []);
      final v = TedCredentials.decode(old);
      final p = TedSavedProfile(tedProfileKey(v), v, purging: !v.offlineAllowed);
      final snapshot = TedProfileSnapshot(p.purging ? null : p.key, [p]);
      await _write(snapshot);
      return snapshot;
    }
    try {
      final data = jsonDecode(raw) as Map;
      if (data['version'] != 1) throw const FormatException();
      final values = (data['profiles'] as List).map((r) {
        final v = TedCredentials.decode(r['credentials'] as String);
        final p = TedSavedProfile(r['key'] as String, v, purging: r['purging'] as bool);
        if (p.key != tedProfileKey(v)) throw const FormatException();
        return p;
      }).toList();
      final active = data['active'] as String?;
      if (values.map((p) => p.key).toSet().length != values.length ||
          active != null && !values.any((p) => p.key == active && !p.purging)) {
        throw const FormatException();
      }
      return TedProfileSnapshot(active, values);
    } catch (_) {
      throw const TedFailure('storage_unavailable');
    }
  }

  Future<void> _write(TedProfileSnapshot value) async {
    final raw = jsonEncode({
      'version': 1,
      'active': value.active,
      'profiles': value.profiles
          .map((p) => {'key': p.key, 'credentials': p.credentials.encode(), 'purging': p.purging})
          .toList(),
    });
    await storage.write(key: key, value: raw);
    if (await storage.read(key: key) != raw) throw const TedFailure('storage_unavailable');
    // Retire a legacy entry only if it exists, after verified publication.
    // Darwin 0.3.2 deletes both synchronizable variants: deleting an absent
    // entry in the login Keychain can return errSecMissingEntitlement from
    // the synchronizable variant even though the ordinary item is absent.
    if (await storage.read(key: legacyKey) != null) {
      await storage.delete(key: legacyKey);
      if (await storage.read(key: legacyKey) != null) throw const TedFailure('storage_unavailable');
    }
  }

  Future<TedProfileSnapshot> read() => _serial(_read);
  Future<void> activate(String? profile) => _serial(() async {
    final v = await _read();
    if (profile != null && !v.profiles.any((p) => p.key == profile && !p.purging)) {
      throw const TedFailure('sign_in_required');
    }
    await _write(TedProfileSnapshot(profile, v.profiles));
  });
  Future<void> finishPurge(String profile) => _serial(() async {
    final v = await _read();
    if (v.profiles.any((p) => p.key == profile && !p.purging)) throw const TedFailure('storage_unavailable');
    await _write(TedProfileSnapshot(v.active, v.profiles.where((p) => p.key != profile).toList()));
  });
  TedProfileStore connection([String? profile]) => TedProfileStore(this, profile);
  Future<void> _save(TedCredentials credentials, {String? expected}) => _serial(() async {
    final v = await _read(), id = tedProfileKey(credentials);
    if (expected != null && id != expected) throw const TedFailure('sign_in_required');
    final old = v.profiles.where((p) => p.key == id).firstOrNull;
    if (old?.purging == true) throw const TedFailure('sign_in_required');
    final purging = !credentials.offlineAllowed;
    await _write(
      TedProfileSnapshot(purging ? null : id, [
        ...v.profiles.where((p) => p.key != id),
        TedSavedProfile(id, credentials, purging: purging),
      ]),
    );
  });
  Future<void> _clear(String profile) => _serial(() async {
    final v = await _read();
    await _write(
      TedProfileSnapshot(v.active == profile ? null : v.active, [
        for (final p in v.profiles)
          if (p.key == profile) TedSavedProfile(p.key, p.credentials, purging: true) else p,
      ]),
    );
  });
}

class TedProfileStore implements TedCredentialStore {
  final TedProfiles profiles;
  String? profile;
  TedProfileStore(this.profiles, this.profile);
  @override
  Future<TedCredentials?> read() async {
    final v = await profiles.read();
    profile ??= v.active;
    return v.profiles.where((p) => p.key == profile && !p.purging).firstOrNull?.credentials;
  }

  @override
  Future<void> save(TedCredentials v) async {
    await profiles._save(v, expected: profile);
    profile = tedProfileKey(v);
  }

  @override
  Future<void> clear() async {
    if (profile != null) await profiles._clear(profile!);
  }
}
