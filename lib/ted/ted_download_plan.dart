import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_source_models.dart';

/// A chosen release, independent of expiring source handles and private URLs.
class TedDownloadSource {
  final String provider, addonId, sourceKey, bingeKey, name;
  const TedDownloadSource.mapped() : provider = 'mapped', addonId = '', sourceKey = '', bingeKey = '', name = '';
  const TedDownloadSource._(this.provider, this.addonId, this.sourceKey, this.bingeKey, this.name);
  factory TedDownloadSource.choice(TedSourceChoice choice) {
    final value = TedDownloadSource._('stremio', choice.addonId, choice.sourceKey, choice.bingeKey, choice.name);
    value.validate();
    return value;
  }
  factory TedDownloadSource.fromJson(Map<String, dynamic> json) {
    try {
      final value = TedDownloadSource._(
        json['provider'] as String,
        json['addon_id'] as String,
        json['source_key'] as String,
        json['binge_key'] as String,
        json['name'] as String,
      );
      value.validate();
      return value;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
  void validate() {
    if (!['mapped', 'stremio'].contains(provider) ||
        !tedSourceKey(addonId) ||
        !tedSourceKey(sourceKey) ||
        !tedSourceKey(bingeKey) ||
        name.length > 256 ||
        provider == 'stremio' && (addonId.isEmpty || sourceKey.isEmpty) ||
        provider == 'mapped' && [addonId, sourceKey, bingeKey, name].any((v) => v.isNotEmpty)) {
      throw const TedFailure('invalid_response');
    }
  }

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'addon_id': addonId,
    'source_key': sourceKey,
    'binge_key': bingeKey,
    'name': name,
  };
  TedSourceChoice? match(TedSourcePage page, {bool nextEpisode = false}) {
    if (provider != 'stremio' || nextEpisode && bingeKey.isEmpty) return null;
    final matches = page.choices
        .where(
          (c) =>
              c.addonId == addonId &&
              (nextEpisode
                  ? c.bingeKey == bingeKey
                  : c.sourceKey == sourceKey || c.previousSourceKeys.contains(sourceKey)),
        )
        .toList();
    return matches.length == 1 ? matches.single : null;
  }
}

class TedDownloadCandidate {
  final TedTitle title;
  final String? fileId, fileSession, queueId;
  const TedDownloadCandidate(this.title, {this.fileId, this.fileSession, this.queueId});
}

class TedPlannedDownload {
  final TedDownloadCandidate candidate;
  final TedDownloadSource source;
  const TedPlannedDownload(this.candidate, this.source);
}

int tedEpisodeDownloadOrder(TedTitle a, TedTitle b) {
  final sa = a.season ?? int.tryParse(a.media.id.split(':').elementAtOrNull(1) ?? '') ?? 0;
  final sb = b.season ?? int.tryParse(b.media.id.split(':').elementAtOrNull(1) ?? '') ?? 0;
  if (sa == 0 && sb != 0) return 1;
  if (sb == 0 && sa != 0) return -1;
  final season = sa.compareTo(sb);
  if (season != 0) return season;
  return (a.episode ?? int.tryParse(a.media.id.split(':').elementAtOrNull(2) ?? '') ?? 0).compareTo(
    b.episode ?? int.tryParse(b.media.id.split(':').elementAtOrNull(2) ?? '') ?? 0,
  );
}

class TedBulkSourceOptions {
  final TedSourcePage page;
  final TedDownloadSource? automatic;
  final TedFailure? error;
  const TedBulkSourceOptions(this.page, {this.automatic, this.error});
}

/// Auto-match only the policy explicitly chosen in this operation. A missing
/// or ambiguous group returns to manual selection rather than another release.
Future<TedBulkSourceOptions> tedBulkSourceOptions(
  TedClient client,
  TedMediaIdentity media,
  TedDownloadSource? previous, {
  bool forceRefresh = false,
}) async {
  TedSourcePage? mapped, addons;
  TedFailure? failure;
  Future<void> loadMapped() async {
    try {
      mapped = await client.mappedSource(media);
    } catch (e) {
      failure = e is TedFailure ? e : const TedFailure('unavailable');
    }
  }

  Future<void> loadAddons() async {
    try {
      addons = await client.stremioSources(
        media,
        preferredAddonId: previous?.addonId ?? '',
        forceRefresh: forceRefresh,
      );
    } catch (e) {
      failure = e is TedFailure ? e : const TedFailure('unavailable');
    }
  }

  if (previous?.provider == 'mapped') {
    await loadMapped();
    if (mapped?.mapped == true && mapped?.ready == true) {
      return TedBulkSourceOptions(mapped!, automatic: const TedDownloadSource.mapped());
    }
    await loadAddons();
  } else if (previous?.provider == 'stremio' && previous!.bingeKey.isNotEmpty) {
    await loadAddons();
    final match = addons == null ? null : previous.match(addons!, nextEpisode: true);
    if (match != null) return TedBulkSourceOptions(addons!, automatic: TedDownloadSource.choice(match));
    await loadMapped();
  } else {
    await Future.wait([loadMapped(), loadAddons()]);
  }
  final page = TedSourcePage(
    mapped?.mapped ?? false,
    mapped?.ready ?? false,
    addons?.choices ?? [],
    addons?.issues ?? [],
    null,
    mappedFileName: mapped?.mappedFileName ?? '',
    addons: addons?.addons ?? [],
    addonIssues: addons?.addonIssues ?? [],
  );
  return TedBulkSourceOptions(page, error: page.choices.isEmpty && !(page.mapped && page.ready) ? failure : null);
}
