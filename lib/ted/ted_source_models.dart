import 'ted_models.dart';

class TedSourceChoice {
  final String id, addon, name, description;
  final String addonId, bingeKey, sourceKey, favoriteKey;
  final bool favorite;
  final bool rdDirectPlay, inRDAccount;
  final List<String> previousSourceKeys;
  final int recentRank;
  const TedSourceChoice(
    this.id,
    this.addon,
    this.name,
    this.description, {
    this.addonId = '',
    this.bingeKey = '',
    this.sourceKey = '',
    this.favoriteKey = '',
    this.favorite = false,
    this.recentRank = 0,
    this.rdDirectPlay = false,
    this.inRDAccount = false,
    this.previousSourceKeys = const [],
  });
  TedSourceChoice withFavorite(bool value) => TedSourceChoice(
    id,
    addon,
    name,
    description,
    addonId: addonId,
    bingeKey: bingeKey,
    sourceKey: sourceKey,
    favoriteKey: favoriteKey,
    favorite: value,
    recentRank: recentRank,
    rdDirectPlay: rdDirectPlay,
    inRDAccount: inRDAccount,
    previousSourceKeys: previousSourceKeys,
  );
}

class TedInstalledAddon {
  final String name;
  final String id;
  final bool movie, episode, supported, enabled;
  const TedInstalledAddon(this.name, this.movie, this.episode, this.supported, {this.id = '', this.enabled = true});
}

class TedAddonCollection {
  final List<TedInstalledAddon> addons;
  final bool cached;
  final DateTime observedAt;
  const TedAddonCollection(this.addons, this.cached, this.observedAt);
  factory TedAddonCollection.fromJson(Map<String, dynamic> data) {
    try {
      final addons = (data['addons'] as List).map((raw) {
        final value = raw as Map<String, dynamic>;
        final name = value['name'] as String;
        if (name.length > 256 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['id'] as String)) {
          throw const TedFailure('invalid_response');
        }
        return TedInstalledAddon(
          name,
          value['movie'] as bool,
          value['episode'] as bool,
          value['supported'] as bool,
          id: value['id'] as String,
          enabled: value['enabled'] as bool? ?? true,
        );
      }).toList();
      if (addons.length > 64) throw const TedFailure('invalid_response');
      return TedAddonCollection(addons, data['cached'] as bool, DateTime.parse(data['observed_at'] as String));
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}

class TedSourceIssue {
  final String addonId, message;
  const TedSourceIssue(this.addonId, this.message);
}

class TedSourcePage {
  final bool mapped, ready;
  final bool lookupUnavailable;
  final bool cached;
  final Set<String> unavailableAddons;
  String get emptyMessage => lookupUnavailable
      ? 'Some add-ons could not be reached. Retry to check for playable sources.'
      : 'No playable sources returned. TED supports direct media files and torrents through Real-Debrid.';
  final List<TedSourceChoice> choices;
  final List<String> issues;
  final String? autoSelect, preferredSource;
  final String mappedFileName;
  final List<TedInstalledAddon> addons;
  final List<TedSourceIssue> addonIssues;
  const TedSourcePage(
    this.mapped,
    this.ready,
    this.choices,
    this.issues,
    this.autoSelect, {
    this.preferredSource,
    this.mappedFileName = '',
    this.addons = const [],
    this.addonIssues = const [],
    this.lookupUnavailable = false,
    this.cached = false,
    this.unavailableAddons = const {},
  });
  TedSourcePage withChoices(List<TedSourceChoice> values) => TedSourcePage(
    mapped,
    ready,
    values,
    issues,
    autoSelect,
    preferredSource: preferredSource,
    mappedFileName: mappedFileName,
    addons: addons,
    addonIssues: addonIssues,
    lookupUnavailable: lookupUnavailable,
    cached: cached,
    unavailableAddons: unavailableAddons,
  );
  factory TedSourcePage.fromJson(Map<String, dynamic> data, TedMediaIdentity media) {
    try {
      if (TedMediaIdentity.fromJson(data['media'] as Map<String, dynamic>) != media ||
          !['mapped', 'addons'].contains(data['mode'])) {
        throw const TedFailure('invalid_response');
      }
      final choices = (data['sources'] as List).map((item) {
        final value = item as Map<String, dynamic>;
        final choice = TedSourceChoice(
          value['id'] as String,
          value['addon'] as String,
          value['name'] as String,
          value['description'] as String,
          addonId: value['addon_id'] as String? ?? '',
          bingeKey: value['binge_key'] as String? ?? '',
          sourceKey: value['source_key'] as String? ?? '',
          favoriteKey: value['favorite_key'] as String? ?? '',
          favorite: value['favorite'] as bool? ?? false,
          recentRank: value['recent_rank'] as int? ?? 0,
          rdDirectPlay: value['rd_direct_play'] as bool? ?? false,
          inRDAccount: value['in_rd_account'] as bool? ?? false,
          previousSourceKeys: (value['previous_source_keys'] as List? ?? []).cast<String>(),
        );
        if (!tedUuid(choice.id) ||
            choice.name.length > 256 ||
            choice.addon.length > 256 ||
            choice.description.length > 4096 ||
            !tedSourceKey(choice.addonId) ||
            !tedSourceKey(choice.bingeKey) ||
            !tedSourceKey(choice.sourceKey) ||
            !tedSourceKey(choice.favoriteKey) ||
            choice.recentRank < 0 ||
            choice.recentRank > 3) {
          throw const TedFailure('invalid_response');
        }
        if (choice.inRDAccount && !choice.rdDirectPlay ||
            choice.previousSourceKeys.any((k) => k.isEmpty || !tedSourceKey(k))) {
          throw const TedFailure('invalid_response');
        }
        return choice;
      }).toList();
      final addonIssues = <TedSourceIssue>[];
      var lookupUnavailable = false;
      final unavailableAddons = <String>{};
      final issues = (data['issues'] as List)
          .map((item) {
            final value = item as Map<String, dynamic>;
            final addon = value['addon'] as String? ?? '';
            final addonId = value['addon_id'] as String? ?? '';
            if (addon.length > 256 || !tedSourceKey(addonId)) throw const TedFailure('invalid_response');
            if (value['code'] == 'addon_unavailable') {
              lookupUnavailable = true;
              if (addonId.isNotEmpty) unavailableAddons.add(addonId);
            }
            final message = switch (value['code']) {
              'addon_collection_cached' => 'Using saved add-ons while Stremio is unavailable.',
              // An individual failed add-on should not interrupt source selection.
              // Keep validating its descriptor; TED retains the diagnostic code.
              'addon_unavailable' => null,
              'unsupported_sources' =>
                '$addon returned unsupported sources. TED supports direct media files and identifiable torrents through Real-Debrid.',
              'source_limit' => '$addon returned more sources than TED can list at once.',
              _ => throw const TedFailure('invalid_response'),
            };
            if (message != null && addonId.isNotEmpty) addonIssues.add(TedSourceIssue(addonId, message));
            return message;
          })
          .nonNulls
          .toList();
      final selected = data['auto_select'] as String?;
      final preferred = data['preferred_source'] as String?;
      if (preferred != null && preferred.isNotEmpty && !choices.any((c) => c.id == preferred)) {
        throw const TedFailure('invalid_response');
      }
      if (choices.length > 200 ||
          choices.map((c) => c.id).toSet().length != choices.length ||
          selected != null && selected.isNotEmpty && !choices.any((c) => c.id == selected)) {
        throw const TedFailure('invalid_response');
      }
      final mapped = data['mode'] == 'mapped';
      if (mapped && choices.isNotEmpty) throw const TedFailure('invalid_response');
      final filename = data['mapped_file_name'] as String? ?? '';
      if (filename.length > 4096 ||
          filename.contains('/') ||
          filename.contains(r'\') ||
          (!mapped && filename.isNotEmpty)) {
        throw const TedFailure('invalid_response');
      }
      final addons = (data['addons'] as List? ?? []).map((raw) {
        final addon = raw as Map<String, dynamic>;
        final id = addon['id'] as String;
        final name = addon['name'] as String;
        if (id.isEmpty || !tedSourceKey(id) || name.length > 256) throw const TedFailure('invalid_response');
        return TedInstalledAddon(
          name,
          addon['movie'] as bool,
          addon['episode'] as bool,
          addon['supported'] as bool,
          id: id,
          enabled: addon['enabled'] as bool? ?? true,
        );
      }).toList();
      if (addons.length > 64 || addons.map((a) => a.id).toSet().length != addons.length) {
        throw const TedFailure('invalid_response');
      }
      return TedSourcePage(
        mapped,
        data['mapped_ready'] as bool,
        choices,
        issues,
        selected == '' ? null : selected,
        preferredSource: preferred == '' ? null : preferred,
        mappedFileName: filename,
        lookupUnavailable: lookupUnavailable,
        cached: data['_cached'] == true,
        unavailableAddons: unavailableAddons,
        addons: addons,
        addonIssues: addonIssues,
      );
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}
