import 'dart:convert';

/// Safe, fixed messages: upstream responses, URLs and tokens never enter logs.
class TedFailure implements Exception {
  final String code;
  const TedFailure(this.code);
  String get message => switch (code) {
    'sign_in_required' => 'Sign in to TED again.',
    'invalid_credentials' => 'TED rejected the username or password.',
    'metadata_identity_unverified' =>
      'The provider’s episode identities could not be verified. Existing history and mappings are preserved.',
    'metadata_still_preparing' => 'Metadata is still being prepared. Reload this series shortly.',
    'metadata_overrides_review_required' =>
      'Manual overrides changed. Reopen the provider confirmation and choose whether to keep or remove them.',
    'metadata_provider_changed' => 'The metadata provider changed. Reload the series before trying again.',
    'metadata_identity_ambiguous' =>
      'The provider’s episode identities could not be verified. Existing history and mappings are preserved.',
    'metadata_refresh_failed' => 'Metadata could not be refreshed. Check the server’s metadata providers and retry.',
    'storage_unavailable' => 'Secure storage is unavailable. Retry access to the system keyring.',
    'release_changed' => 'The mapped file changed. Select the item again.',
    'mapping_not_ready' => 'This item does not have a ready TED mapping.',
    'rate_limited' => 'Too many sign-in attempts. Try again later.',
    'conflict' => 'TED rejected an out-of-order update. Reload the item.',
    'incompatible_version' => 'TED and Teddy must use compatible versions. Update your app or server.',
    'invalid_response' => 'TED returned an invalid response.',
    'catalog_unavailable' ||
    'catalog_incomplete' => 'Cinemeta is unavailable. Previously viewed titles and personal progress remain available.',
    'catalog_not_found' => 'Cinemeta does not have this title or episode.',
    'catalog_invalid' => 'This catalog request is invalid.',
    'stremio_not_linked' => 'An administrator must connect the server Stremio add-on account in TED.',
    'stremio_link_changed' => 'The server add-on connection changed. Reload sources.',
    'stremio_credentials_rejected' =>
      'Your Stremio session expired. Relink Stremio in TED’s Account screen, then refresh add-ons.',
    'source_selection_required' => 'The source expired or changed. Find sources and choose again.',
    'source_unsupported' => 'This source does not support direct file playback and seeking.',
    'addon_unavailable' => 'Add-on sources are unavailable. Retry source discovery.',
    'source_preparation_unavailable' ||
    'source_unavailable' => 'The selected source could not be prepared. Retry or choose another source.',
    'source_placeholder' =>
      'This source returned a short status video instead of the requested title. Your watch progress was preserved.',
    'rd_source_pending' => 'Real-Debrid is preparing or downloading this torrent. Try again when it is ready.',
    'rd_infringing' => 'Real-Debrid blocked this file for copyright infringement. Choose another source.',
    'rd_rejected' => 'Real-Debrid rejected this torrent or file. Choose another source.',
    'rd_not_configured' => 'An administrator must configure the Real-Debrid key in TED’s Server providers.',
    'rd_credentials' => 'Real-Debrid rejected TED’s configured key. Check the RD account and server settings.',
    'rd_limited' => 'Real-Debrid is rate limiting requests. Wait a moment and retry.',
    'rd_unavailable' => 'Real-Debrid could not prepare this file. Retry or choose another source.',
    'source_archive' => 'Real-Debrid returned an archive instead of this video. Choose another source.',
    'playback_failed' => 'The player could not play this source. Retry playback or choose another source.',
    'playback_interrupted' =>
      'The stream ended before the video finished. Reconnect or choose another source; your position is saved.',
    'track_unavailable' => 'The player could not switch tracks. Retry playback or choose another track.',
    'sync_pending' => 'Playback progress is saved on this device and waiting to sync. Open Downloads to retry.',
    'download_exists' => 'This item is already in Downloads on this device.',
    'download_paused' => 'Download paused. Sign in to the same account and resume from Downloads.',
    'download_changed' => 'The file or saved download changed. Remove this device copy and select the source again.',
    'download_failed' => 'Download failed. Check the connection and retry from Downloads.',
    'download_unavailable' => 'This episode could not be prepared for download. Retry from Downloads.',
    'no_supported_sources' => 'No supported direct-file or RD torrent sources returned for this episode.',
    'download_in_use' => 'Stop offline playback before removing this device copy.',
    _ => 'TED is unavailable. Check the server and connection.',
  };
  @override
  String toString() => 'TedFailure($code)';
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
bool tedUuid(String value) => _uuid.hasMatch(value);

class TedMediaIdentity {
  final String kind;
  final String id;
  const TedMediaIdentity(this.kind, this.id);
  factory TedMediaIdentity.fromJson(Map<String, dynamic> json) {
    final value = TedMediaIdentity(json['kind'] as String, json['id'] as String);
    if (!value.valid) throw const TedFailure('invalid_response');
    return value;
  }
  bool get valid => switch (kind) {
    'movie' => RegExp(r'^tt[0-9]{7,12}$').hasMatch(id),
    'series' => RegExp(r'^tt[0-9]{7,12}$').hasMatch(id),
    'episode' => RegExp(r'^tt[0-9]{7,12}:[0-9]{1,4}:[0-9]{1,5}$').hasMatch(id),
    _ => false,
  };
  bool get playable => kind == 'movie' || kind == 'episode';
  Map<String, dynamic> toJson() => {'kind': kind, 'id': id};
  @override
  bool operator ==(Object other) => other is TedMediaIdentity && kind == other.kind && id == other.id;
  @override
  int get hashCode => Object.hash(kind, id);
}

Uri tedServerUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path != '' && uri.path != '/')) {
    throw const TedFailure('invalid_response');
  }
  return uri.replace(path: '/');
}

class TedTokens {
  final String access;
  final String refresh;
  final String familyId;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
  final DateTime familyExpiresAt;
  final int expiresIn;
  final int userId;
  final String displayName;
  final Map<String, dynamic> _json;
  TedTokens._(
    this.access,
    this.refresh,
    this.familyId,
    this.accessExpiresAt,
    this.refreshExpiresAt,
    this.familyExpiresAt,
    this.expiresIn,
    this.userId,
    this.displayName,
    this._json,
  );
  factory TedTokens.fromJson(Map<String, dynamic> json) {
    try {
      final user = json['user'] as Map<String, dynamic>;
      final value = TedTokens._(
        json['access_token'] as String,
        json['refresh_token'] as String,
        json['family_id'] as String,
        DateTime.parse(json['access_expires_at'] as String).toUtc(),
        DateTime.parse(json['refresh_expires_at'] as String).toUtc(),
        DateTime.parse(json['family_expires_at'] as String).toUtc(),
        json['expires_in'] as int,
        user['id'] as int,
        user['display_name'] as String,
        Map<String, dynamic>.from(json),
      );
      if (json['token_type'] != 'Bearer' ||
          !RegExp(r'^ted_a_[A-Za-z0-9_-]{43}$').hasMatch(value.access) ||
          !RegExp(r'^ted_r_[A-Za-z0-9_-]{43}$').hasMatch(value.refresh) ||
          !tedUuid(value.familyId) ||
          value.userId < 1 ||
          value.expiresIn < 1 ||
          value.expiresIn > 315360000 ||
          value.accessExpiresAt.isAfter(value.refreshExpiresAt) ||
          value.refreshExpiresAt.isAfter(value.familyExpiresAt)) {
        throw const TedFailure('invalid_response');
      }
      return value;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_json);
  @override
  String toString() => 'TedTokens(redacted)';
}

/// One OS-store value contains the whole pair and its recovery state. A pending
/// rotation may already have committed remotely, so restore must never retry it.
class TedCredentials {
  final Uri server;
  final String deviceId;
  final TedTokens tokens;
  final bool refreshPending;
  final bool offlineAllowed;
  const TedCredentials(
    this.server,
    this.deviceId,
    this.tokens, {
    this.refreshPending = false,
    this.offlineAllowed = true,
  });
  String encode() => jsonEncode({
    'version': 2,
    'server': server.toString(),
    'device_id': deviceId,
    'state': refreshPending ? 'refresh_pending' : 'ready',
    'offline_allowed': offlineAllowed,
    'tokens': tokens.toJson(),
  });
  factory TedCredentials.decode(String raw) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (![1, 2].contains(data['version']) ||
          (data['version'] == 2 && data['offline_allowed'] is! bool) ||
          !['ready', 'refresh_pending'].contains(data['state']) ||
          !tedUuid(data['device_id'] as String)) {
        throw const TedFailure('invalid_response');
      }
      return TedCredentials(
        tedServerUri(data['server'] as String),
        data['device_id'] as String,
        TedTokens.fromJson(data['tokens'] as Map<String, dynamic>),
        refreshPending: data['state'] != 'ready',
        offlineAllowed: data['version'] == 2 ? data['offline_allowed'] as bool : data['state'] == 'ready',
      );
    } catch (_) {
      throw const TedFailure('sign_in_required');
    }
  }
  @override
  String toString() => 'TedCredentials(redacted)';
}

class TedPlaybackSession {
  final String id;
  final TedMediaIdentity media;
  final String mediaPath;
  final int durationMs;
  final int expectedDurationMs;
  final int resumeMs;
  final List<String> audioLanguages;
  final String originalLanguage;
  final List<TedSubtitle> subtitles;
  final int watchRevision;
  final String source, addonId, bingeKey, downloadSourceSession;
  const TedPlaybackSession(
    this.id,
    this.media,
    this.mediaPath,
    this.durationMs,
    this.resumeMs, {
    this.audioLanguages = const ['en'],
    this.originalLanguage = '',
    this.subtitles = const [],
    this.watchRevision = 0,
    this.source = 'mapped_rd',
    this.addonId = '',
    this.bingeKey = '',
    this.downloadSourceSession = '',
    this.expectedDurationMs = 0,
  });
  factory TedPlaybackSession.fromJson(Map<String, dynamic> data, TedMediaIdentity expected) {
    try {
      final value = TedPlaybackSession(
        data['id'] as String,
        TedMediaIdentity.fromJson(data['media'] as Map<String, dynamic>),
        data['media_url'] as String,
        data['duration_ms'] as int,
        data['resume_ms'] as int,
        expectedDurationMs: data['expected_duration_ms'] as int? ?? 0,
        watchRevision: (data['watch_revision'] as int?) ?? 0,
        source: data['source'] as String? ?? 'mapped_rd',
        addonId: data['addon_id'] as String? ?? '',
        bingeKey: data['binge_key'] as String? ?? '',
        audioLanguages: (data['audio_languages'] as List).cast<String>(),
        originalLanguage: data['original_language'] as String? ?? '',
        subtitles: ((data['subtitles'] as List?) ?? [])
            .map((item) => TedSubtitle.fromJson(item as Map<String, dynamic>, data['id'] as String))
            .toList(),
      );
      if (!expected.playable ||
          !value.media.playable ||
          !tedUuid(value.id) ||
          value.media != expected ||
          value.mediaPath != '/api/client/v1/playback/sessions/${value.id}/media' ||
          value.durationMs < 0 ||
          (value.durationMs == 0 && data['source'] != 'addon') ||
          value.durationMs > 604800000 ||
          value.expectedDurationMs < 0 ||
          value.expectedDurationMs > 604800000 ||
          value.resumeMs < 0 ||
          value.resumeMs > 604800000 ||
          value.durationMs > 0 && value.resumeMs > value.durationMs ||
          value.subtitles.length > 64) {
        throw const TedFailure('invalid_response');
      }
      if (!['mapped_rd', 'local', 'addon'].contains(value.source) ||
          !tedSourceKey(value.addonId) ||
          !tedSourceKey(value.bingeKey) ||
          value.source != 'addon' && (value.addonId.isNotEmpty || value.bingeKey.isNotEmpty)) {
        throw const TedFailure('invalid_response');
      }
      if (value.originalLanguage.isNotEmpty && !RegExp(r'^[a-z]{2,3}$').hasMatch(value.originalLanguage)) {
        throw const TedFailure('invalid_response');
      }
      if (value.audioLanguages.isEmpty ||
          value.audioLanguages.length > 4 ||
          value.audioLanguages.any((language) => !['en', 'ja', 'zh', 'ko'].contains(language))) {
        throw const TedFailure('invalid_response');
      }
      return value;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}

bool tedSourceKey(String key) => key.isEmpty || RegExp(r'^[a-f0-9]{64}$').hasMatch(key);

class TedSubtitle {
  final String path, language, label;
  final String codec;
  const TedSubtitle(this.path, this.language, this.label, {this.codec = ''});
  factory TedSubtitle.fromJson(Map<String, dynamic> data, String session) {
    final path = data['url'] as String;
    if (!RegExp('^/api/client/v1/playback/sessions/$session/subtitles/[0-9]{1,2}\$').hasMatch(path)) {
      throw const TedFailure('invalid_response');
    }
    final codec = data['codec'] as String? ?? '';
    if (!['', 'subrip', 'webvtt', 'ass', 'ssa'].contains(codec)) throw const TedFailure('invalid_response');
    return TedSubtitle(path, data['language'] as String, data['label'] as String, codec: codec);
  }
}
