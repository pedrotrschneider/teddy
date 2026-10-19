import 'dart:typed_data';
import 'ted_rating.dart';
import 'ted_joint_watch.dart';
import 'ted_user_watch.dart';
import 'dart:convert';
import 'ted_source_cache.dart';
import 'ted_home_cache.dart';
import 'dart:async';
import 'ted_preparation.dart';
import 'ted_auth.dart';
import 'ted_models.dart';
import 'ted_episode_navigation.dart';
import 'ted_source_models.dart';
import 'ted_metadata_models.dart';
import 'ted_series_models.dart';
import 'ted_download_watch.dart';
import '../utils/app_logger.dart';
import 'package:http/http.dart' as http;

class TedTitle {
  final bool watchlist;
  final int? userRating;
  final List<TedUserWatch> userWatches;
  final List<TedJointWatch> jointWatches;
  final TedMediaIdentity media;
  final String name;
  final String description;
  final bool played;
  final int revision;
  final int positionMs;
  final bool local;
  final bool ready;
  final String poster, background, year, runtime, metadataStatus;
  final String logo, seriesName, episodeName, episodePoster;
  final double? rating;
  final List<String> genres;
  final TedMediaIdentity? parent;
  final int? season, episode, durationMs;
  final int? episodeCount, watchedEpisodeCount;
  final List<int> seasons;
  final List<TedCatalogIssue> issues;
  final TedMetadataSnapshot? enrichment;
  final DateTime? releaseDate;
  const TedTitle(
    this.media,
    this.name,
    this.description,
    this.played,
    this.revision,
    this.positionMs,
    this.local, {
    this.watchlist = false,
    this.userRating,
    this.userWatches = const [],
    this.jointWatches = const [],
    this.ready = false,
    this.poster = '',
    this.background = '',
    this.year = '',
    this.runtime = '',
    this.metadataStatus = 'retained',
    this.logo = '',
    this.seriesName = '',
    this.episodeName = '',
    this.episodePoster = '',
    this.rating,
    this.genres = const [],
    this.parent,
    this.season,
    this.episode,
    this.durationMs,
    this.episodeCount,
    this.watchedEpisodeCount,
    this.seasons = const [],
    this.issues = const [],
    this.enrichment,
    this.releaseDate,
  });
  TedTitle withEnrichment(TedMetadataSnapshot snapshot) => _copy(enrichment: snapshot);
  TedTitle withPreferences(TedTitlePreferences preferences) => _copy(preferences: preferences);
  TedTitle _copy({TedMetadataSnapshot? enrichment, TedTitlePreferences? preferences}) => TedTitle(
    media,
    name,
    description,
    played,
    revision,
    positionMs,
    local,
    watchlist: preferences?.watchlist ?? watchlist,
    userRating: preferences == null ? userRating : preferences.rating,
    userWatches: userWatches,
    jointWatches: jointWatches,
    ready: ready,
    poster: poster,
    background: background,
    year: year,
    runtime: runtime,
    metadataStatus: metadataStatus,
    logo: logo,
    seriesName: seriesName,
    episodeName: episodeName,
    episodePoster: episodePoster,
    rating: rating,
    genres: genres,
    parent: parent,
    season: season,
    episode: episode,
    durationMs: durationMs,
    episodeCount: episodeCount,
    watchedEpisodeCount: watchedEpisodeCount,
    seasons: seasons,
    issues: issues,
    enrichment: enrichment ?? this.enrichment,
    releaseDate: releaseDate,
  );
  factory TedTitle.fromJson(Map<String, dynamic> data) {
    try {
      final preferences = TedTitlePreferences.fromJson(data);
      final media = TedMediaIdentity.fromJson(data['media'] as Map<String, dynamic>);
      final meta = data['metadata'] as Map<String, dynamic>;
      final state = data['watch_state'] as Map<String, dynamic>;
      final episode = meta['episode'] as Map<String, dynamic>?;
      final series = meta['series'] as Map<String, dynamic>?;
      final counts = data['episode_counts'] as Map<String, dynamic>?;
      final name = media.kind == 'episode'
          ? '${series?['name'] ?? 'Series'} · ${episode?['name'] ?? media.id}'
          : meta['name'] as String? ?? media.id;
      final value = TedTitle(
        media,
        name,
        episode?['description'] as String? ?? meta['description'] as String? ?? '',
        state['played'] as bool,
        state['revision'] as int,
        state['position_ms'] as int,
        data['local_available'] as bool,
        watchlist: preferences.watchlist,
        userRating: preferences.rating,
        userWatches: ((data['user_watches'] as List?) ?? [])
            .map((e) => TedUserWatch.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        jointWatches: ((data['joint_watches'] as List?) ?? [])
            .map((e) => TedJointWatch.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        ready: data['mapped_ready'] as bool,
        poster: _art(meta['poster']),
        background: _art(meta['background']),
        year: meta['year'] as String? ?? '',
        runtime: meta['runtime'] as String? ?? '',
        metadataStatus: data['metadata_status'] as String? ?? 'retained',
        logo: _art(meta['logo']),
        seriesName: series?['name'] as String? ?? '',
        episodeName: episode?['name'] as String? ?? '',
        episodePoster: _art(episode?['image']),
        releaseDate: DateTime.tryParse(episode?['release_date'] as String? ?? meta['released'] as String? ?? ''),
        rating: (meta['imdb_rating'] as num?)?.toDouble(),
        genres: ((meta['genres'] as List?) ?? []).cast<String>(),
        parent: data['parent'] == null ? null : TedMediaIdentity.fromJson(data['parent'] as Map<String, dynamic>),
        season: episode?['season'] as int?,
        episode: episode?['number'] as int?,
        durationMs: state['duration_ms'] as int?,
        episodeCount: counts == null ? null : counts['total'] as int,
        watchedEpisodeCount: counts == null ? null : counts['watched'] as int,
        seasons: ((data['seasons'] as List?) ?? []).cast<int>(),
        issues: ((data['issues'] as List?) ?? [])
            .map((e) => TedCatalogIssue.fromJson(e as Map<String, dynamic>))
            .toList(),
        enrichment: data['enrichment'] == null
            ? null
            : TedMetadataSnapshot.fromJson(data['enrichment'] as Map<String, dynamic>),
      );
      if (value.revision < 0 ||
          (counts != null &&
              (media.kind != 'series' ||
                  value.episodeCount! < 0 ||
                  value.watchedEpisodeCount! < 0 ||
                  value.watchedEpisodeCount! > value.episodeCount! ||
                  value.played != (value.episodeCount! > 0 && value.watchedEpisodeCount == value.episodeCount))) ||
          (value.enrichment != null &&
              value.enrichment!.type !=
                  switch (media.kind) {
                    'movie' => 'Movie',
                    'series' => 'Series',
                    _ => 'Episode',
                  }) ||
          value.positionMs < 0 ||
          value.positionMs > 604800000 ||
          (value.durationMs != null && (value.durationMs! <= 0 || value.durationMs! > 604800000)) ||
          !['fresh', 'cached', 'retained'].contains(value.metadataStatus) ||
          value.seasons.length > 10000 ||
          value.seasons.any((s) => s < 0 || s > 9999) ||
          (value.parent != null &&
              (media.kind != 'episode' ||
                  value.parent!.kind != 'series' ||
                  value.parent!.id != media.id.split(':').first))) {
        throw const TedFailure('invalid_response');
      }
      return value;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}

String _art(dynamic value) {
  if (value == null || value == '') return '';
  final uri = Uri.tryParse(value as String);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      !['images.metahub.space', 'live.metahub.space', 'm.media-amazon.com', 'image.tmdb.org'].contains(uri.authority)) {
    return '';
  }
  return uri.toString();
}

class TedCatalogIssue {
  final String code;
  final TedMediaIdentity? media;
  const TedCatalogIssue(this.code, this.media);
  factory TedCatalogIssue.fromJson(Map<String, dynamic> data) {
    final code = data['code'] as String;
    if (![
      'catalog_cached',
      'catalog_unavailable',
      'catalog_incomplete',
      'schedule_unavailable',
      'metadata_unavailable',
    ].contains(code)) {
      throw const TedFailure('invalid_response');
    }
    return TedCatalogIssue(
      code,
      data['media'] == null ? null : TedMediaIdentity.fromJson(data['media'] as Map<String, dynamic>),
    );
  }
  String get message => switch (code) {
    'catalog_cached' => 'Showing saved metadata while Cinemeta is unavailable.',
    'schedule_unavailable' =>
      'Episode schedule unavailable for ${media?.id ?? 'a series'}. Next Up is incomplete; TED will retry.',
    'metadata_unavailable' => 'Some saved title details are unavailable.',
    _ => 'Cinemeta is unavailable. Retry to load this row.',
  };
}

List<TedTitle> _titles(dynamic raw, int limit) {
  final values = (raw as List).map((e) => TedTitle.fromJson(e as Map<String, dynamic>)).toList();
  if (values.length > limit || values.map((t) => t.media).toSet().length != values.length) {
    throw const TedFailure('invalid_response');
  }
  return values;
}

class TedCatalogPage {
  final List<TedTitle> titles;
  final int? nextSkip;
  final String? nextAfter;
  const TedCatalogPage(this.titles, this.nextSkip, {this.nextAfter});
  factory TedCatalogPage.fromJson(Map<String, dynamic> data) {
    try {
      final page = TedCatalogPage(
        _titles(data['titles'], 200),
        data['next_skip'] as int?,
        nextAfter: data['next_after'] as String?,
      );
      if (page.nextSkip != null && (page.nextSkip! < 50 || page.nextSkip! > 10000 || page.nextSkip! % 50 != 0)) {
        throw const TedFailure('invalid_response');
      }
      if (page.nextAfter != null &&
          (page.nextSkip != null ||
              page.titles.isEmpty ||
              page.nextAfter != page.titles.last.media.id ||
              !TedMediaIdentity('movie', page.nextAfter!).valid)) {
        throw const TedFailure('invalid_response');
      }
      return page;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}

class TedPersonalPage {
  final List<TedTitle> titles;
  final String? nextAfter;
  final List<TedCatalogIssue> issues;
  const TedPersonalPage(this.titles, this.nextAfter, this.issues);
  factory TedPersonalPage.fromJson(Map<String, dynamic> data) {
    try {
      final cursor = data['next_after'] as String?;
      if (cursor != null && cursor.length > 512) throw const TedFailure('invalid_response');
      return TedPersonalPage(
        _titles(data['titles'], 50),
        cursor == '' ? null : cursor,
        (data['issues'] as List).map((e) => TedCatalogIssue.fromJson(e as Map<String, dynamic>)).toList(),
      );
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}

class TedEpisodePage {
  final List<TedTitle> titles;
  final int? nextAfter;
  final TedMetadataSnapshot? enrichment;
  const TedEpisodePage(this.titles, this.nextAfter, {this.enrichment});
  factory TedEpisodePage.fromJson(Map<String, dynamic> data) {
    try {
      final page = TedEpisodePage(
        _titles(data['titles'], 50),
        data['next_after'] as int?,
        enrichment: data['enrichment'] == null
            ? null
            : TedMetadataSnapshot.fromJson(data['enrichment'] as Map<String, dynamic>),
      );
      if (page.enrichment != null && page.enrichment!.type != 'Season') throw const TedFailure('invalid_response');
      if (page.nextAfter != null && (page.nextAfter! < 0 || page.nextAfter! > 99999)) {
        throw const TedFailure('invalid_response');
      }
      return page;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}

class TedHomeRow {
  final String id;
  final List<TedTitle> titles;
  final bool unavailable;
  final List<TedCatalogIssue> issues;
  final bool loading;
  const TedHomeRow(this.id, this.titles, this.unavailable, this.issues, {this.loading = false});
  factory TedHomeRow.fromJson(Map<String, dynamic> data) {
    try {
      final id = data['id'] as String;
      if (![
        'continue-watching',
        'new-releases',
        'next-up',
        'watchlist',
        'popular-movie',
        'popular-series',
      ].contains(id)) {
        throw const TedFailure('invalid_response');
      }
      return TedHomeRow(
        id,
        _titles(data['titles'], 50),
        data['unavailable'] as bool,
        (data['issues'] as List).map((e) => TedCatalogIssue.fromJson(e as Map<String, dynamic>)).toList(),
      );
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}

class TedMappedPage {
  final List<TedTitle> titles;
  final String? nextAfter;
  const TedMappedPage(this.titles, this.nextAfter);
}

class TedClient {
  final TedAuth auth;
  final TedSourceCache? sourceCache;
  final TedHomeCache? homeCache;
  int _homeGeneration = 0;
  TedClient(this.auth, {this.sourceCache, this.homeCache});
  String get _sourceScope => jsonEncode([auth.server.toString(), auth.userId, auth.deviceId]);
  final _preparations = <String, TedPreparation>{};
  final _sourceLookups = <String, Future<TedSourcePage>>{};
  final _preparedPages = <TedMediaIdentity, TedSourcePage>{};
  void stagePreparedSources(TedMediaIdentity media, TedSourcePage page) {
    _preparedPages[media] = page;
  }

  TedSourcePage? takePreparedSources(TedMediaIdentity media) => _preparedPages.remove(media);
  TedPreparation prepareSource(TedMediaIdentity media, String sourceId) {
    return _preparations.putIfAbsent(sourceId, () => TedPreparation(auth, media, sourceId));
  }

  void discardPreparation(TedPreparation? preparation) {
    if (preparation == null) return;
    if (identical(_preparations[preparation.sourceId], preparation)) _preparations.remove(preparation.sourceId);
    preparation.discard();
  }

  Future<TedMetadataSnapshot> season(String id, int season) async {
    if (!TedMediaIdentity('series', id).valid || season < 0 || season > 9999) {
      throw const TedFailure('invalid_response');
    }
    final result = TedMetadataSnapshot.fromJson(
      await auth.json('GET', '/api/client/v1/titles/series/${Uri.encodeComponent(id)}/seasons/$season/metadata'),
    );
    if (result.type != 'Season') throw const TedFailure('invalid_response');
    return result;
  }

  Future<TedSeriesWatch> seriesWatch(String id) async {
    if (!TedMediaIdentity('series', id).valid) throw const TedFailure('invalid_response');
    return TedSeriesWatch.fromJson(
      await auth.json('GET', '/api/client/v1/titles/series/${Uri.encodeComponent(id)}/watch-state'),
      id,
    );
  }

  Future<void> setSeriesWatched(String id, String version, bool watched) async {
    if (!TedMediaIdentity('series', id).valid || !RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) {
      throw const TedFailure('invalid_response');
    }
    TedSeriesWatch.fromJson(
      await auth.json(
        'POST',
        '/api/client/v1/titles/series/${Uri.encodeComponent(id)}/watch-state',
        body: {'version': version, 'watched': watched},
      ),
      id,
    );
  }

  Future<TedSeriesWatch> seasonWatch(String id, int season) async {
    if (!TedMediaIdentity('series', id).valid || season < 0 || season > 9999) {
      throw const TedFailure('invalid_response');
    }
    return TedSeriesWatch.fromJson(
      await auth.json('GET', '/api/client/v1/titles/series/${Uri.encodeComponent(id)}/seasons/$season/watch-state'),
      id,
      season: season,
    );
  }

  Future<void> setSeasonWatched(String id, int season, String version, bool watched) async {
    if (!TedMediaIdentity('series', id).valid ||
        season < 0 ||
        season > 9999 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) {
      throw const TedFailure('invalid_response');
    }
    TedSeriesWatch.fromJson(
      await auth.json(
        'POST',
        '/api/client/v1/titles/series/${Uri.encodeComponent(id)}/seasons/$season/watch-state',
        body: {'version': version, 'watched': watched},
      ),
      id,
      season: season,
    );
  }

  Future<List<TedTitle>> allEpisodes(TedTitle show, {int? season}) async {
    if (show.media.kind != 'series' || (season != null && (season < 0 || season > 9999))) {
      throw const TedFailure('invalid_response');
    }
    final titles = <TedTitle>[];
    for (final season in season == null ? show.seasons : [season]) {
      int? after;
      do {
        final page = await episodes(show.media.id, season, after: after);
        if (page.nextAfter != null && after != null && page.nextAfter! <= after) {
          throw const TedFailure('invalid_response');
        }
        titles.addAll(page.titles);
        if (titles.length > 10000) throw const TedFailure('invalid_response');
        after = page.nextAfter;
      } while (after != null);
    }
    if (titles.length > 10000 || titles.map((t) => t.media).toSet().length != titles.length) {
      throw const TedFailure('invalid_response');
    }
    return titles;
  }

  Future<TedMetadataSnapshot> person(String id) async {
    if (!tedUuid(id)) throw const TedFailure('invalid_response');
    final result = TedMetadataSnapshot.fromJson(await auth.json('GET', '/api/client/v1/metadata/people/$id'));
    if (result.id != id || result.type != 'Person') throw const TedFailure('invalid_response');
    return result;
  }

  Future<TedFilmographyPage> filmography(String id, {String? after}) async {
    if (!tedUuid(id) || (after != null && !tedUuid(after))) throw const TedFailure('invalid_response');
    return TedFilmographyPage.fromJson(
      await auth.json('GET', '/api/client/v1/metadata/people/$id/filmography${after == null ? '' : '?after=$after'}'),
    );
  }

  Future<String> originalLanguage(TedMediaIdentity media, {bool Function()? current}) async {
    final identity = media.kind == 'episode' ? TedMediaIdentity('series', media.id.split(':').first) : media;
    var snapshot = (await title(identity)).enrichment;
    for (var attempt = 0; snapshot?.pending == true && attempt < 20; attempt++) {
      if (current != null && !current()) return '';
      await Future<void>.delayed(const Duration(seconds: 1));
      if (current != null && !current()) return '';
      snapshot = await metadata(snapshot!.id);
    }
    return snapshot?.originalLanguage ?? '';
  }

  Future<TedMetadataSnapshot> metadata(String id) async {
    if (!tedUuid(id)) throw const TedFailure('invalid_response');
    final result = TedMetadataSnapshot.fromJson(await auth.json('GET', '/api/client/v1/metadata/items/$id'));
    if (result.id != id) throw const TedFailure('invalid_response');
    return result;
  }

  Future<Uint8List?> metadataImage(String id) async {
    final response = await auth.artwork(id);
    return _imageBytes(response);
  }

  final _userPictures = <String, Future<Uint8List?>>{};
  final _userPictureFailures = <String, DateTime>{};
  Future<Uint8List?> userPicture(TedUserWatch watch) {
    if (watch.avatarVersion.isEmpty) return Future.value(null);
    final key = '$_sourceScope/${watch.accountId}/${watch.avatarVersion}';
    final failed = _userPictureFailures[key];
    if (failed != null && auth.now().difference(failed) >= const Duration(minutes: 1)) {
      _userPictures.remove(key);
      _userPictureFailures.remove(key);
    }
    if (_userPictures.length >= 64 && !_userPictures.containsKey(key)) {
      final oldest = _userPictures.keys.first;
      _userPictures.remove(oldest);
      _userPictureFailures.remove(oldest);
    }
    final cached = _userPictures[key];
    if (cached != null) return cached;
    late final Future<Uint8List?> pending;
    pending = _fetchUserPicture(watch).then((image) {
      if (image == null && identical(_userPictures[key], pending)) _userPictureFailures[key] = auth.now();
      return image;
    });
    _userPictures[key] = pending;
    return pending;
  }

  Future<Uint8List?> _fetchUserPicture(TedUserWatch watch) async {
    try {
      final response = await auth.userPicture(watch.accountId);
      if (response.statusCode == 204 || response.headers['content-type']?.split(';').first != 'image/png') {
        return null;
      }
      final data = response.bodyBytes;
      const signature = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82];
      if (data.length < 33 || data.length > 512 << 10) return null;
      for (var i = 0; i < signature.length; i++) {
        if (data[i] != signature[i]) return null;
      }
      final dimensions = ByteData.sublistView(data);
      if (dimensions.getUint32(16) != 256 || dimensions.getUint32(20) != 256) return null;
      return data;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> personPortrait(String id) async => _imageBytes(await auth.personPortrait(id));

  Uint8List? _imageBytes(http.Response response) {
    if (response.statusCode == 202) return null;
    if (response.statusCode != 200 ||
        !const ['image/jpeg', 'image/png', 'image/gif'].contains(response.headers['content-type']?.split(';').first) ||
        response.bodyBytes.isEmpty) {
      throw const TedFailure('invalid_response');
    }
    return response.bodyBytes;
  }

  Future<TedMappedPage> mappedTitles({String? after}) async {
    if (after != null && !tedUuid(after)) throw const TedFailure('invalid_response');
    final data = await auth.json('GET', '/api/client/v1/titles/mapped${after == null ? '' : '?after=$after'}');
    try {
      final values = (data['titles'] as List).map((item) => TedTitle.fromJson(item as Map<String, dynamic>)).toList();
      final next = data['next_after'] as String?;
      if (values.length > 50 || (next != null && !tedUuid(next))) throw const TedFailure('invalid_response');
      return TedMappedPage(values, next);
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }

  Future<TedPlaybackSession> createSession(TedMediaIdentity media, {String? sourceId}) async {
    return createSelectedSession(media, sourceId: sourceId);
  }

  Future<TedPlaybackSession> createSelectedSession(
    TedMediaIdentity media, {
    String? sourceId,
    bool fromBeginning = false,
    Future<void>? abortTrigger,
  }) async {
    if (!media.playable || !media.valid) throw const TedFailure('invalid_response');
    if (sourceId != null && !tedUuid(sourceId)) throw const TedFailure('invalid_response');
    final started = Stopwatch()..start();
    final preparation = _preparations.remove(sourceId);
    var cancelled = false;
    unawaited(abortTrigger?.then((_) => cancelled = true));
    final server = auth.server, user = auth.userId;
    try {
      if (preparation != null) await preparation.consume(abortTrigger: abortTrigger);
      for (var attempt = 0; ; attempt++) {
        if (cancelled || auth.server != server || auth.userId != user) throw const TedFailure('sign_in_required');
        try {
          final session = TedPlaybackSession.fromJson(
            await auth.json(
              'POST',
              '/api/client/v1/playback/sessions',
              abortTrigger: abortTrigger,
              body: {'media': media.toJson(), 'source_id': ?sourceId, if (fromBeginning) 'start_from_beginning': true},
            ),
            media,
          );
          appLogger.i(
            'TED session prepared: media=${media.kind}/${media.id} session=${session.id} '
            'attempt=${attempt + 1} elapsed_ms=${started.elapsedMilliseconds}',
          );
          return session;
        } on TedFailure catch (failure) {
          appLogger.w(
            'TED session attempt failed: media=${media.kind}/${media.id} attempt=${attempt + 1} '
            'code=${failure.code} elapsed_ms=${started.elapsedMilliseconds} cancelled=$cancelled',
          );
          if (cancelled ||
              attempt >= 3 ||
              !const {
                'unavailable',
                'rd_unavailable',
                'source_unavailable',
                'source_preparation_unavailable',
              }.contains(failure.code)) {
            rethrow;
          }
          await Future.any<void>([Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1))), ?abortTrigger]);
        }
      }
    } catch (error) {
      appLogger.w(
        'TED session failed: media=${media.kind}/${media.id} '
        'code=${error is TedFailure ? error.code : "invalid_response"} elapsed_ms=${started.elapsedMilliseconds}',
      );
      rethrow;
    }
  }

  Future<String> setSourceFavorite(String id, bool favorite) async {
    if (!tedUuid(id)) throw const TedFailure('invalid_response');
    final result = await auth.json('PUT', '/api/client/v1/playback/sources/$id/favorite', body: {'favorite': favorite});
    final key = result['favorite_key'];
    if (result['favorite'] != favorite || key is! String || key.isEmpty || !tedSourceKey(key)) {
      throw const TedFailure('invalid_response');
    }
    await sourceCache?.favorite(_sourceScope, key, favorite);
    return key;
  }

  Future<TedSourcePage> stremioSources(
    TedMediaIdentity media, {
    bool forceRefresh = false,
    String preferredAddonId = '',
    Future<void>? abortTrigger,
  }) async {
    if (!media.playable || !media.valid || !tedSourceKey(preferredAddonId)) {
      throw const TedFailure('invalid_response');
    }
    final scope = _sourceScope;
    final key = '$scope/${media.kind}/${media.id}';
    final existing = _sourceLookups[key];
    if (existing != null) return existing;
    final lookup = () async {
      if (!forceRefresh && sourceCache != null && auth.signedIn) {
        final cached = await sourceCache!.read(scope, media);
        if (cached != null) return TedSourcePage.fromJson(cached, media);
      }
      final started = Stopwatch()..start();
      final raw = await auth.json(
        'POST',
        '/api/client/v1/playback/sources',
        abortTrigger: abortTrigger,
        body: {
          'media': media.toJson(),
          'provider': 'stremio',
          if (preferredAddonId.isNotEmpty) 'preferred_addon': preferredAddonId,
        },
      );
      final page = TedSourcePage.fromJson(raw, media);
      appLogger.i(
        'TED sources loaded: media=${media.kind}/${media.id} elapsed_ms=${started.elapsedMilliseconds} '
        'choices=${page.choices.length} partial=${page.lookupUnavailable}',
      );
      if (_sourceScope == scope) await sourceCache?.write(scope, media, raw);
      return page;
    }();
    _sourceLookups[key] = lookup;
    try {
      return await lookup;
    } finally {
      if (identical(_sourceLookups[key], lookup)) unawaited(_sourceLookups.remove(key));
    }
  }

  Future<TedSourcePage> mappedSource(TedMediaIdentity media) async {
    return _providerSources(media, 'mapped');
  }

  Future<TedSourcePage> _providerSources(
    TedMediaIdentity media,
    String provider, {
    String preferredAddonId = '',
    Future<void>? abortTrigger,
  }) async {
    if (!media.playable || !media.valid) throw const TedFailure('invalid_response');
    return TedSourcePage.fromJson(
      await auth.json(
        'POST',
        '/api/client/v1/playback/sources',
        abortTrigger: abortTrigger,
        body: {
          'media': media.toJson(),
          'provider': provider,
          if (preferredAddonId.isNotEmpty) 'preferred_addon': preferredAddonId,
        },
      ),
      media,
    );
  }

  Future<TedSourcePage> sources(TedMediaIdentity media, {String? previousSession}) async {
    if (!media.playable || !media.valid || previousSession != null && !tedUuid(previousSession)) {
      throw const TedFailure('invalid_response');
    }
    return TedSourcePage.fromJson(
      await auth.json(
        'POST',
        '/api/client/v1/playback/sources',
        body: {'media': media.toJson(), 'previous_session': ?previousSession},
      ),
      media,
    );
  }

  Future<TedAddonCollection> addons({bool refresh = false}) async =>
      TedAddonCollection.fromJson(await auth.json('GET', '/api/client/v1/addons${refresh ? '?refresh=1' : ''}'));

  Future<TedTitle?> nextForShow(String id) async {
    if (!TedMediaIdentity('series', id).valid) throw const TedFailure('invalid_response');
    String? after;
    final cursors = <String>{};
    do {
      final page = await personal('next-up', after: after);
      if (page.issues.any((issue) => issue.media == null || issue.media!.id.split(':').first == id)) {
        throw const TedFailure('catalog_unavailable');
      }
      final next = page.titles.where((item) => item.media.kind == 'episode' && item.parent?.id == id).firstOrNull;
      if (next != null) return next;
      after = page.nextAfter;
      if (after != null && (!cursors.add(after) || cursors.length > 1000)) {
        throw const TedFailure('invalid_response');
      }
    } while (after != null);
    return null;
  }

  Future<TedEpisodeTargets> adjacentEpisodes(TedMediaIdentity media) async {
    if (media.kind != 'episode' || !media.valid) return const TedEpisodeTargets();
    final data = await auth.json('GET', '/api/client/v1/titles/episode/${Uri.encodeComponent(media.id)}/adjacent');
    TedTitle? read(String key) {
      if (data[key] == null) return null;
      final title = TedTitle.fromJson(data[key] as Map<String, dynamic>);
      if (title.media.kind != 'episode' ||
          title.media.id == media.id ||
          title.media.id.split(':').first != media.id.split(':').first) {
        throw const TedFailure('invalid_response');
      }
      final a = media.id.split(':').skip(1).map(int.parse).toList();
      final b = title.media.id.split(':').skip(1).map(int.parse).toList();
      final comparison = b[0] == a[0] ? b[1].compareTo(a[1]) : b[0].compareTo(a[0]);
      if (key == 'previous' ? comparison >= 0 : comparison <= 0) throw const TedFailure('invalid_response');
      return title;
    }

    return TedEpisodeTargets(previous: read('previous'), next: read('next'));
  }

  Future<TedCatalogPage> browse(
    String kind, {
    String search = '',
    int skip = 0,
    String catalog = 'popular',
    String genre = '',
    bool mapped = false,
    String watched = 'all',
    String? after,
  }) async {
    if (!['movie', 'series'].contains(kind)) throw const TedFailure('invalid_response');
    final query = Uri(
      queryParameters: {
        'skip': '$skip',
        if (search.isNotEmpty) 'search': search,
        'catalog': catalog,
        if (genre.isNotEmpty) 'genre': genre,
        if (mapped) 'mapped': 'true',
        if (watched != 'all') 'watched': watched,
        'after': ?after,
      },
    ).query;
    final timer = Stopwatch()..start();
    final mode = search.isNotEmpty
        ? 'search'
        : ['popular', 'new'].contains(catalog)
        ? catalog
        : 'filtered';
    try {
      final page = TedCatalogPage.fromJson(await auth.json('GET', '/api/client/v1/catalog/$kind?$query'));
      if (page.titles.any((title) => title.media.kind != kind) ||
          (search.isNotEmpty && (page.nextSkip != null || page.nextAfter != null)) ||
          (page.nextSkip != null && page.nextSkip! <= skip) ||
          page.nextAfter != null && page.nextAfter == after) {
        throw const TedFailure('invalid_response');
      }
      appLogger.i(
        'Catalog page loaded kind=$kind mode=$mode skip=$skip titles=${page.titles.length} elapsed_ms=${timer.elapsedMilliseconds}',
      );
      return page;
    } catch (error) {
      appLogger.w(
        'Catalog page failed kind=$kind mode=$mode skip=$skip elapsed_ms=${timer.elapsedMilliseconds} failure=${error is TedFailure ? error.code : error.runtimeType}',
      );
      rethrow;
    }
  }

  Future<TedTitle> title(TedMediaIdentity media) async {
    if (!media.valid) throw const TedFailure('invalid_response');
    final title = TedTitle.fromJson(
      await auth.json(
        'GET',
        '/api/client/v1/titles/${Uri.encodeComponent(media.kind)}/${Uri.encodeComponent(media.id)}',
      ),
    );
    if (title.media != media) throw const TedFailure('invalid_response');
    return title;
  }

  Future<Map<TedMediaIdentity, TedDownloadWatch>> downloadWatches(List<TedMediaIdentity> media) async {
    if (media.isEmpty ||
        media.length > 200 ||
        media.toSet().length != media.length ||
        media.any((v) => !v.valid || !v.playable)) {
      throw const TedFailure('invalid_response');
    }
    final data = await auth.json(
      'POST',
      '/api/client/v1/downloads/watch-state',
      body: {'media': media.map((v) => v.toJson()).toList()},
    );
    try {
      final result = <TedMediaIdentity, TedDownloadWatch>{};
      for (final raw in data['items'] as List) {
        final item = TedDownloadWatch.fromJson(raw as Map<String, dynamic>);
        if (!media.contains(item.media) || result.containsKey(item.media)) throw const TedFailure('invalid_response');
        result[item.media] = item;
      }
      if (result.length != media.length) throw const TedFailure('invalid_response');
      return result;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }

  Future<TedTitlePreferences> setTitlePreference(
    TedMediaIdentity media,
    String field, {
    bool? watchlist,
    int? rating,
  }) async {
    if (!['movie', 'series'].contains(media.kind) || !media.valid || !['watchlist', 'rating'].contains(field)) {
      throw const TedFailure('invalid_response');
    }
    final scope = _sourceScope;
    final state = TedTitlePreferences.fromJson(
      await auth.json(
        'PUT',
        '/api/client/v1/titles/${media.kind}/${Uri.encodeComponent(media.id)}/preferences/$field',
        body: field == 'watchlist' ? {'watchlist': watchlist} : {'user_rating': rating},
      ),
    );
    if (scope != _sourceScope) throw const TedFailure('sign_in_required');
    return state;
  }

  Future<TedPersonalPage> collection(String list, {String kind = '', String? after}) async {
    if (list != 'watchlist' && !RegExp(r'^ratings/[0-7]$').hasMatch(list)) throw const TedFailure('invalid_response');
    final q = Uri(queryParameters: {'kind': kind, 'after': after ?? ''}).query;
    final page = TedPersonalPage.fromJson(await auth.json('GET', '/api/client/v1/collections/$list?$q'));
    if (page.titles.any(
      (t) => !['movie', 'series'].contains(t.media.kind) || (kind.isNotEmpty && t.media.kind != kind),
    )) {
      throw const TedFailure('invalid_response');
    }
    return page;
  }

  Future<TedPersonalPage> personal(String row, {String? after}) async {
    if (!['continue-watching', 'new-releases', 'next-up', 'watchlist'].contains(row)) {
      throw const TedFailure('invalid_response');
    }
    return TedPersonalPage.fromJson(
      await auth.json(
        'GET',
        '/api/client/v1/rows/$row${after == null ? '' : '?after=${Uri.encodeQueryComponent(after)}'}',
      ),
    );
  }

  Future<TedEpisodePage> episodes(String id, int season, {int? after}) async {
    final page = TedEpisodePage.fromJson(
      await auth.json(
        'GET',
        '/api/client/v1/titles/series/${Uri.encodeComponent(id)}/episodes?season=$season${after == null ? '' : '&after=$after'}',
      ),
    );
    if (page.titles.any(
      (title) => title.media.kind != 'episode' || title.media.id.split(':').first != id || title.season != season,
    )) {
      throw const TedFailure('invalid_response');
    }
    return page;
  }

  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async {
    final generation = ++_homeGeneration;
    final scope = _sourceScope;
    bool current() => generation == _homeGeneration && scope == _sourceScope && auth.signedIn;
    const ids = ['continue-watching', 'new-releases', 'next-up', 'watchlist', 'popular-movie', 'popular-series'];
    final rows = [for (final id in ids) TedHomeRow(id, const [], false, const [], loading: true)];
    for (var i = 0; i < ids.length; i++) {
      try {
        rows[i] = await homeCache?.read(scope, ids[i]) ?? rows[i];
      } catch (_) {
        appLogger.w('Home shelf cache could not be read; fetching current data');
      }
    }
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].id == 'watchlist') {
        rows[i] = TedHomeRow(
          'watchlist',
          [...rows[i].titles]..shuffle(),
          rows[i].unavailable,
          rows[i].issues,
          loading: rows[i].loading,
        );
      }
    }
    if (!current()) return const [];
    TedFailure? authFailure;
    // Personal rows are database reads. Discovery must not hold them behind
    // an external provider or turn an individual outage into an empty Home.
    onUpdate?.call(List.unmodifiable(rows));
    await Future.wait([
      for (var i = 0; i < ids.length; i++)
        () async {
          final id = ids[i];
          try {
            final Map<String, dynamic> data;
            if (id.startsWith('popular-')) {
              final kind = id.substring('popular-'.length);
              data = await auth.json('GET', '/api/client/v1/catalog/$kind?skip=0&catalog=popular');
              final page = TedCatalogPage.fromJson(data);
              if (page.titles.any((title) => title.media.kind != kind)) throw const TedFailure('invalid_response');
            } else {
              data = await auth.json('GET', '/api/client/v1/rows/$id');
              TedPersonalPage.fromJson(data);
            }
            if (!current()) return;
            final snapshot = {'id': id, 'titles': data['titles'], 'issues': data['issues'] ?? [], 'unavailable': false};
            final fresh = TedHomeRow.fromJson(snapshot);
            rows[i] = fresh.issues.isNotEmpty && !rows[i].loading
                ? TedHomeRow(id, rows[i].titles, false, fresh.issues)
                : fresh;
            onUpdate?.call(List.unmodifiable(rows));
            try {
              await homeCache?.write(scope, snapshot);
            } catch (_) {
              appLogger.w('Home shelf cache could not be saved');
            }
          } catch (error) {
            if (error is TedFailure && error.code == 'sign_in_required') authFailure = error;
            if (!current()) return;
            rows[i] = TedHomeRow(id, rows[i].titles, true, const []);
            onUpdate?.call(List.unmodifiable(rows));
          }
        }(),
    ]);
    if (authFailure != null) throw authFailure!;
    return List.unmodifiable(rows);
  }

  Future<void> setWatched(TedTitle title, bool watched) async {
    if (!title.media.playable) throw const TedFailure('invalid_response');
    await auth.json(
      'POST',
      '/api/client/v1/watch-state',
      body: {'media': title.media.toJson(), 'revision': title.revision, 'action': watched ? 'watched' : 'unwatched'},
    );
  }

  Future<void> events(List<Map<String, dynamic>> events, {List<Map<String, dynamic>> sessions = const []}) async {
    final result = await auth.json(
      'POST',
      '/api/client/v1/playback/events',
      body: {'events': events, 'sessions': sessions},
    );
    try {
      final acknowledged = result['events'] as List;
      if (acknowledged.length != events.length) throw const TedFailure('invalid_response');
      for (var i = 0; i < events.length; i++) {
        final ack = acknowledged[i] as Map<String, dynamic>;
        if (ack['id'] != events[i]['id'] || !['applied', 'stale', 'ignored'].contains(ack['outcome'])) {
          throw const TedFailure('invalid_response');
        }
      }
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}
