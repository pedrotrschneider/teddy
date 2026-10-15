import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'ted_credential_store.dart';
import 'ted_models.dart';
import 'ted_version.dart';

/// Exactly one owner per connection. Native player/download adapters ask this
/// owner for headers; they never load a family independently in another isolate.
class TedAuth {
  final TedCredentialStore store;
  final http.Client client;
  final DateTime Function() now;
  final Duration requestTimeout;
  final Duration playbackPreparationTimeout;
  final Duration sourceLookupTimeout;
  TedCredentials? _credentials;
  Future<void> _tail = Future<void>.value();
  Future<void>? _refreshing;
  bool _closed = false;
  int _epoch = 0;
  String? _deviceId;

  /// This identity permits access to already downloaded device files only.
  /// It is never a token or authorization for a TED request.
  TedCredentials? _offlineIdentity;
  TedAuth({
    required this.store,
    http.Client? client,
    DateTime Function()? now,
    this.requestTimeout = const Duration(seconds: 10),
    this.playbackPreparationTimeout = const Duration(seconds: 50),
    this.sourceLookupTimeout = const Duration(seconds: 30),
    String? deviceId,
  }) : client = client ?? http.Client(),
       now = now ?? DateTime.now,
       // A named private initializing formal would hide the bootstrap argument.
       // ignore: prefer_initializing_formals
       _deviceId = deviceId;

  Uri? get server => _credentials?.server;
  String? get displayName => _credentials?.tokens.displayName;
  String? get familyId => _credentials?.tokens.familyId;
  int? get userId => _credentials?.tokens.userId;
  DateTime? get accessExpiresAt => _credentials?.tokens.accessExpiresAt;
  bool get signedIn => _credentials != null && !_closed;
  Uri? get offlineServer => _offlineIdentity?.server;
  int? get offlineUserId => _offlineIdentity?.tokens.userId;
  String? get deviceId => _deviceId;

  Future<T> _exclusive<T>(Future<T> Function() work) {
    final result = _tail.then((_) {
      if (_closed) throw const TedFailure('sign_in_required');
      return work();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> restore() => _exclusive(() async {
    _epoch++;
    _credentials = null;
    _offlineIdentity = null;
    final value = await store.read();
    if (value == null) return false;
    _deviceId = value.deviceId;
    if (value.offlineAllowed) _offlineIdentity = value;
    if (value.refreshPending ||
        !now().isBefore(value.tokens.refreshExpiresAt) ||
        !now().isBefore(value.tokens.familyExpiresAt)) {
      throw const TedFailure('sign_in_required');
    }
    _credentials = value;
    _offlineIdentity = value;
    return true;
  });

  Future<void> login(String server, String username, String password, String deviceName) => _exclusive(() async {
    _epoch++;
    _credentials = null;
    _offlineIdentity = null;
    final base = tedServerUri(server);
    final device = _deviceId ??= const Uuid().v4();
    final response = await _send(
      base,
      'POST',
      '/api/client/v1/auth/login',
      body: {'username': username, 'password': password, 'device_id': device, 'device_name': deviceName},
    );
    if (response.statusCode == 401) throw const TedFailure('invalid_credentials');
    _requireSuccess(response);
    final value = TedCredentials(base, device, TedTokens.fromJson(_object(response)));
    try {
      await store.save(value);
    } catch (_) {
      await _invalidateStored(value);
      throw const TedFailure('storage_unavailable');
    }
    if (_closed) throw const TedFailure('sign_in_required');
    _credentials = value;
    _offlineIdentity = value;
  });

  Future<void> _rotate() => _exclusive(() async {
    final old = _credentials;
    if (old == null || !now().isBefore(old.tokens.refreshExpiresAt) || !now().isBefore(old.tokens.familyExpiresAt)) {
      _credentials = null;
      throw const TedFailure('sign_in_required');
    }
    try {
      await store.save(TedCredentials(old.server, old.deviceId, old.tokens, refreshPending: true));
      final response = await _send(
        old.server,
        'POST',
        '/api/client/v1/auth/refresh',
        body: {'refresh_token': old.tokens.refresh},
      );
      _requireSuccess(response);
      final tokens = TedTokens.fromJson(_object(response));
      if (tokens.familyId != old.tokens.familyId ||
          tokens.userId != old.tokens.userId ||
          tokens.familyExpiresAt != old.tokens.familyExpiresAt ||
          tokens.refresh == old.tokens.refresh) {
        throw const TedFailure('invalid_response');
      }
      final replacement = TedCredentials(old.server, old.deviceId, tokens);
      await store.save(replacement);
      if (_closed) throw const TedFailure('sign_in_required');
      _credentials = replacement;
    } catch (_) {
      // Never retry the old refresh token after uncertain commit/save. Pending
      // state is retained for crash recovery; a new login creates a new family.
      _credentials = null;
      await _invalidateStored(old);
      throw const TedFailure('sign_in_required');
    }
  });

  Future<void> refresh() {
    final active = _refreshing;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _rotate().whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
    });
    _refreshing = operation;
    return operation;
  }

  Future<Map<String, String>> headers() async {
    if (_closed || _credentials == null) throw const TedFailure('sign_in_required');
    if (_refreshing != null) await _refreshing;
    final value = _credentials;
    if (value == null) throw const TedFailure('sign_in_required');
    // A one-second safety margin works with short development TTLs too.
    if (!now().add(const Duration(seconds: 1)).isBefore(value.tokens.accessExpiresAt)) await refresh();
    final token = _credentials?.tokens.access;
    if (_closed || token == null) throw const TedFailure('sign_in_required');
    return {'Authorization': 'Bearer $token', 'X-Teddy-Compatibility-Major': teddyCompatibilityMajor};
  }

  Future<Map<String, dynamic>> json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Future<void>? abortTrigger,
  }) async {
    return _object(await _authenticated(method, path, body: body, abortTrigger: abortTrigger));
  }

  /// Artwork uses the same rotating credential owner as API/player requests.
  /// Tokens never become image URLs or enter a global network-image cache.
  Future<http.Response> artwork(String id) {
    if (!tedUuid(id)) throw const TedFailure('invalid_response');
    return _authenticated('GET', '/api/client/v1/metadata/images/$id', maxBytes: 20 << 20);
  }

  /// Resolves an already-seeded person portrait without requesting biography
  /// or filmography enrichment. The route accepts only a TED entity UUID.
  Future<http.Response> personPortrait(String id) {
    if (!tedUuid(id)) throw const TedFailure('invalid_response');
    return _authenticated('GET', '/api/client/v1/metadata/items/$id/images/Primary', maxBytes: 20 << 20);
  }

  Future<http.Response> _authenticated(
    String method,
    String path, {
    Map<String, dynamic>? body,
    int maxBytes = 2 << 20,
    Future<void>? abortTrigger,
  }) async {
    final first = await headers();
    final base = server!;
    final epoch = _epoch;
    var response = await _send(
      base,
      method,
      path,
      headers: first,
      body: body,
      maxBytes: maxBytes,
      abortTrigger: abortTrigger,
    );
    if (epoch != _epoch || _closed) throw const TedFailure('sign_in_required');
    if (response.statusCode == 401) {
      // Another waiting API request may already have rotated this credential.
      if (_credentials == null) throw const TedFailure('sign_in_required');
      if (first['Authorization'] == 'Bearer ${_credentials!.tokens.access}') await refresh();
      if (epoch != _epoch || _closed) throw const TedFailure('sign_in_required');
      response = await _send(
        base,
        method,
        path,
        headers: await headers(),
        body: body,
        maxBytes: maxBytes,
        abortTrigger: abortTrigger,
      );
      if (epoch != _epoch || _closed) throw const TedFailure('sign_in_required');
      if (response.statusCode == 401) {
        _credentials = null;
        throw const TedFailure('sign_in_required');
      }
    }
    _requireSuccess(response);
    return response;
  }

  Future<void> logout({bool all = false}) => _exclusive(() async {
    _epoch++;
    final old = _credentials ?? _offlineIdentity;
    _credentials = null;
    _offlineIdentity = null;
    // A durable pending marker prevents resurrection if deletion fails/crashes.
    if (old != null) {
      await store.save(
        TedCredentials(old.server, old.deviceId, old.tokens, refreshPending: true, offlineAllowed: false),
      );
    }
    try {
      if (old != null) {
        final response = await _send(
          old.server,
          'POST',
          '/api/client/v1/auth/logout${all ? '-all' : ''}',
          headers: {'Authorization': 'Bearer ${old.tokens.access}'},
        );
        if (response.statusCode != 401) _requireSuccess(response);
      }
    } finally {
      await store.clear();
    }
  });

  Future<http.Response> _send(
    Uri base,
    String method,
    String path, {
    Map<String, String>? headers,
    Map<String, dynamic>? body,
    int maxBytes = 2 << 20,
    Future<void>? abortTrigger,
  }) async {
    if (_closed || !path.startsWith('/api/client/v1/') || path.contains('://') || path.contains('#')) {
      throw const TedFailure('invalid_response');
    }
    final abort = Completer<void>();
    // Source aggregation and selected-file preparation each have a bounded
    // network budget. Keep login/refresh/search on their ordinary deadline.
    final budget =
        method == 'POST' &&
            (path == '/api/client/v1/playback/preparations' ||
                path == '/api/client/v1/playback/sessions' ||
                path == '/api/client/v1/downloads/resolve')
        ? playbackPreparationTimeout
        : method == 'POST' && path == '/api/client/v1/playback/sources'
        ? sourceLookupTimeout
        : requestTimeout;
    final timer = Timer(budget, () {
      if (!abort.isCompleted) abort.complete();
    });
    unawaited(
      abortTrigger?.then((_) {
        if (!abort.isCompleted) abort.complete();
      }),
    );
    final request = http.AbortableRequest(method, base.resolve(path), abortTrigger: abort.future)
      ..followRedirects = false
      ..headers.addAll({
        'Accept': 'application/json',
        ...?headers,
        'X-Teddy-Compatibility-Major': teddyCompatibilityMajor,
      });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await client.send(request);
      final bytes = <int>[];
      await for (final part in response.stream) {
        if (bytes.length + part.length > maxBytes) throw const TedFailure('invalid_response');
        bytes.addAll(part);
      }
      return http.Response.bytes(bytes, response.statusCode, headers: response.headers);
    } on TedFailure {
      rethrow;
    } catch (_) {
      throw const TedFailure('unavailable');
    } finally {
      timer.cancel();
    }
  }

  Map<String, dynamic> _object(http.Response response) {
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }

  void _requireSuccess(http.Response response) {
    // Older servers omitted the header and belong to compatibility major zero.
    final serverMajor = response.headers['x-ted-compatibility-major'] ?? '0';
    if (serverMajor != teddyCompatibilityMajor) throw const TedFailure('incompatible_version');
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 401) throw const TedFailure('sign_in_required');
    if (response.statusCode == 426) throw const TedFailure('incompatible_version');
    if (response.statusCode == 429) throw const TedFailure('rate_limited');
    String? code;
    try {
      code = _object(response)['code'] as String?;
    } catch (_) {
      /* fixed fallback */
    }
    throw TedFailure(switch (code) {
      'catalog_unavailable' ||
      'catalog_incomplete' ||
      'catalog_not_found' ||
      'catalog_invalid' ||
      'release_changed' ||
      'mapping_not_ready' ||
      'stremio_not_linked' ||
      'stremio_link_changed' ||
      'stremio_credentials_rejected' ||
      'source_selection_required' ||
      'source_unsupported' ||
      'source_preparation_unavailable' ||
      'addon_unavailable' => code!,
      _ => response.statusCode == 409 ? 'conflict' : 'unavailable',
    });
  }

  Future<void> _invalidateStored(TedCredentials value) async {
    try {
      await store.save(
        TedCredentials(
          value.server,
          value.deviceId,
          value.tokens,
          refreshPending: true,
          offlineAllowed: value.offlineAllowed,
        ),
      );
    } catch (_) {
      /* storage failure remains visible; never reuse in memory */
    }
  }

  Future<void> suspend() async {
    close();
    await _tail;
  }

  void close() {
    _epoch++;
    _closed = true;
    _credentials = null;
    client.close();
  }
}
