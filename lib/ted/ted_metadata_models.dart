import 'ted_rating.dart';
import 'ted_joint_watch.dart';
import 'ted_user_watch.dart';
import 'ted_models.dart';

// Provider controls describe manual edits across the entire series, including
// seasons hidden by the selected provider's structure.
class TedSeriesMetadataProvider {
  final String provider, status, error, overridesVersion;
  final bool canChange;
  final int artworkOverrides, metadataOverrides;
  const TedSeriesMetadataProvider({
    required this.provider,
    required this.canChange,
    required this.status,
    required this.error,
    required this.overridesVersion,
    required this.artworkOverrides,
    required this.metadataOverrides,
  });
  bool get hasOverrides => artworkOverrides + metadataOverrides > 0;
  factory TedSeriesMetadataProvider.fromJson(Map<String, dynamic> data) {
    final provider = data['provider'], status = data['status'], error = data['error_code'];
    final revision = data['revision'], canChange = data['can_change'], overrides = data['overrides'];
    if (provider is! String ||
        !const ['Tmdb', 'Tvdb'].contains(provider) ||
        status is! String ||
        !const ['new', 'queued', 'ready', 'partial', 'failed', 'missing', 'not_configured'].contains(status) ||
        error is! String ||
        revision is! int ||
        revision < 0 ||
        canChange is! bool ||
        overrides is! Map<String, dynamic>) {
      throw const TedFailure('invalid_response');
    }
    final artwork = overrides['artwork'], metadata = overrides['metadata'], version = overrides['version'];
    if (artwork is! int ||
        artwork < 0 ||
        metadata is! int ||
        metadata < 0 ||
        version is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) {
      throw const TedFailure('invalid_response');
    }
    return TedSeriesMetadataProvider(
      provider: provider,
      canChange: canChange,
      status: status,
      error: error,
      artworkOverrides: artwork,
      metadataOverrides: metadata,
      overridesVersion: version,
    );
  }
}

class TedMetadataSnapshot {
  final bool scopedCast;
  final String id, status, name, overview, type;
  final int generation;
  final String originalLanguage;
  final int? year;
  final double? rating;
  final DateTime? premiereDate, endDate;
  final List<String> productionLocations;
  final String? certification;
  final List<TedMetadataAsset> images;
  final List<TedMetadataPerson> people;
  const TedMetadataSnapshot({
    required this.id,
    required this.status,
    required this.generation,
    required this.name,
    required this.overview,
    required this.type,
    required this.images,
    this.people = const [],
    this.scopedCast = false,
    this.originalLanguage = '',
    this.year,
    this.rating,
    this.certification,
    this.premiereDate,
    this.endDate,
    this.productionLocations = const [],
  });
  bool get pending => status == 'new' || status == 'queued';
  bool get unavailable => const ['partial', 'failed', 'missing', 'not_configured'].contains(status);
  factory TedMetadataSnapshot.fromJson(Map<String, dynamic> json) {
    try {
      final item = json['item'] as Map<String, dynamic>;
      final value = TedMetadataSnapshot(
        id: item['Id'] as String,
        status: json['status'] as String,
        generation: json['generation'] as int,
        name: item['Name'] as String? ?? '',
        overview: item['Overview'] as String? ?? '',
        type: item['Type'] as String,
        scopedCast: json['scoped_cast'] as bool? ?? false,
        originalLanguage: json['original_language'] as String? ?? '',
        year: item['ProductionYear'] as int?,
        rating: (item['CommunityRating'] as num?)?.toDouble(),
        certification: item['OfficialRating'] as String?,
        premiereDate: _date(item['PremiereDate']),
        endDate: _date(item['EndDate']),
        productionLocations: (item['ProductionLocations'] as List? ?? const []).cast<String>(),
        images: (json['images'] as List).map((v) => TedMetadataAsset.fromJson(v as Map<String, dynamic>)).toList(),
        people: (item['People'] as List? ?? const [])
            .map((v) => TedMetadataPerson.fromJson(v as Map<String, dynamic>))
            .toList(),
      );
      if (!tedUuid(value.id) ||
          value.generation < 0 ||
          !const ['new', 'queued', 'ready', 'partial', 'failed', 'missing', 'not_configured'].contains(value.status) ||
          !const ['Movie', 'Series', 'Episode', 'Season', 'Person'].contains(value.type) ||
          value.images.length > 1000 ||
          value.people.length > 10000 ||
          value.productionLocations.length > 1000) {
        throw const TedFailure('invalid_response');
      }
      return value;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}

DateTime? _date(dynamic value) {
  if (value == null) return null;
  final date = DateTime.tryParse(value as String);
  if (date == null || date.year < 1 || date.year > 9999) throw const TedFailure('invalid_response');
  return date.toUtc();
}

/// Provider summaries remain separate from playable TED catalogue identities.
/// Unresolved appearances remain visible, with unknown personal classification.
class TedFilmographyEntry {
  final bool watchlist;
  final int? userRating;
  final List<TedUserWatch> userWatches;
  final List<TedJointWatch> jointWatches;
  final String id, type, name, overview, identityStatus;
  final int? year;
  final TedMediaIdentity? media;
  final bool? watched, viewed;
  final int? episodeCount, watchedEpisodeCount;
  final List<String> roles;
  final List<TedMetadataAsset> images;

  /// Person rows include read-only joint viewing without merging completion
  /// or progress into the active account's own state.
  bool get hasViewing => viewed == true || jointWatches.any((watch) => watch.seen);
  const TedFilmographyEntry({
    this.watchlist = false,
    this.userRating,
    this.userWatches = const [],
    this.jointWatches = const [],
    required this.id,
    required this.type,
    required this.name,
    required this.overview,
    required this.identityStatus,
    required this.media,
    required this.watched,
    required this.viewed,
    required this.roles,
    required this.images,
    this.year,
    this.episodeCount,
    this.watchedEpisodeCount,
  });
  factory TedFilmographyEntry.fromJson(Map<String, dynamic> json) {
    final item = json['item'] as Map<String, dynamic>;
    final preferences = TedTitlePreferences.fromJson(json);
    final value = TedFilmographyEntry(
      watchlist: preferences.watchlist,
      userRating: preferences.rating,
      userWatches: ((json['user_watches'] as List?) ?? [])
          .map((e) => TedUserWatch.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      jointWatches: ((json['joint_watches'] as List?) ?? [])
          .map((e) => TedJointWatch.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      id: item['Id'] as String,
      type: item['Type'] as String,
      name: item['Name'] as String? ?? '',
      overview: item['Overview'] as String? ?? '',
      year: item['ProductionYear'] as int?,
      identityStatus: json['identity_status'] as String,
      media: json['media'] == null ? null : TedMediaIdentity.fromJson(json['media'] as Map<String, dynamic>),
      watched: json['watched'] as bool?,
      viewed: json['viewed'] as bool?,
      episodeCount: (json['episode_counts'] as Map?)?['total'] as int?,
      watchedEpisodeCount: (json['episode_counts'] as Map?)?['watched'] as int?,
      roles: (json['roles'] as List? ?? const []).cast<String>(),
      images: (json['images'] as List).map((v) => TedMetadataAsset.fromJson(v as Map<String, dynamic>)).toList(),
    );
    if (!tedUuid(value.id) ||
        !['Movie', 'Series'].contains(value.type) ||
        !['new', 'queued', 'ready', 'missing', 'failed'].contains(value.identityStatus) ||
        value.images.length > 1000 ||
        value.roles.length > 1000 ||
        ((value.episodeCount == null) != (value.watchedEpisodeCount == null)) ||
        (value.episodeCount != null &&
            (value.type != 'Series' ||
                value.episodeCount! < 0 ||
                value.watchedEpisodeCount! < 0 ||
                value.watchedEpisodeCount! > value.episodeCount!)) ||
        (value.media != null && value.media!.kind != (value.type == 'Movie' ? 'movie' : 'series')) ||
        (value.media == null && (value.watched != null || value.viewed != null))) {
      throw const TedFailure('invalid_response');
    }
    return value;
  }
}

class TedFilmographyPage {
  final bool pending;
  final List<TedFilmographyEntry> items;
  final String? nextAfter;
  const TedFilmographyPage(this.items, this.nextAfter, {this.pending = false});
  factory TedFilmographyPage.fromJson(Map<String, dynamic> json) {
    try {
      final value = TedFilmographyPage(
        (json['items'] as List).map((v) => TedFilmographyEntry.fromJson(v as Map<String, dynamic>)).toList(),
        json['next_after'] as String?,
        pending: json['pending'] as bool? ?? false,
      );
      if (value.items.length > 20 ||
          (value.nextAfter != null && !tedUuid(value.nextAfter!)) ||
          value.items.map((v) => v.id).toSet().length != value.items.length) {
        throw const TedFailure('invalid_response');
      }
      return value;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}

class TedMetadataPerson {
  final String id, name, type, role;
  final String? imageTag;
  const TedMetadataPerson({required this.id, required this.name, required this.type, this.role = '', this.imageTag});
  factory TedMetadataPerson.fromJson(Map<String, dynamic> json) {
    final person = TedMetadataPerson(
      id: json['Id'] as String,
      name: json['Name'] as String,
      type: json['Type'] as String,
      role: json['Role'] as String? ?? '',
      imageTag: json['PrimaryImageTag'] as String?,
    );
    if (!tedUuid(person.id) ||
        person.name.trim().isEmpty ||
        person.type.isEmpty ||
        person.name.length > 1024 ||
        person.role.length > 4096 ||
        (person.imageTag?.length ?? 0) > 1000) {
      throw const TedFailure('invalid_response');
    }
    return person;
  }
}

class TedMetadataAsset {
  final String id, type, status;
  final int index;
  final String tag;
  final bool userModified;
  const TedMetadataAsset(this.id, this.type, this.index, this.status, {this.tag = '', this.userModified = false});
  factory TedMetadataAsset.fromJson(Map<String, dynamic> json) {
    final v = TedMetadataAsset(
      json['id'] as String,
      json['type'] as String,
      json['index'] as int,
      json['status'] as String,
      tag: json['tag'] as String? ?? '',
      userModified: json['user_modified'] as bool? ?? false,
    );
    if (!tedUuid(v.id) ||
        v.index < 0 ||
        v.index > 100 ||
        json['url'] != '/api/client/v1/metadata/images/${v.id}' ||
        !const ['Primary', 'Backdrop', 'Banner', 'Logo', 'Thumb', 'Art', 'Disc', 'Screenshot'].contains(v.type) ||
        !const ['new', 'queued', 'ready', 'failed'].contains(v.status)) {
      throw const TedFailure('invalid_response');
    }
    return v;
  }
}
