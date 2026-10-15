import 'ted_models.dart';
import 'ted_source_models.dart';

/// Device-local preference, never a playback grant or an expiring source ID.
class TedSeasonSource {
  final String provider, addonId, bingeKey;
  const TedSeasonSource(this.provider, {this.addonId = '', this.bingeKey = ''});
  factory TedSeasonSource.fromSession(TedPlaybackSession session) => TedSeasonSource(
    session.source == 'addon' ? 'stremio' : 'mapped',
    addonId: session.addonId,
    bingeKey: session.bingeKey,
  );
  factory TedSeasonSource.fromJson(Map<String, dynamic> json) {
    final value = TedSeasonSource(
      json['provider'] as String,
      addonId: json['addon_id'] as String,
      bingeKey: json['binge_key'] as String,
    );
    if (!['mapped', 'stremio'].contains(value.provider) ||
        !tedSourceKey(value.addonId) ||
        !tedSourceKey(value.bingeKey) ||
        value.provider == 'mapped' && (value.addonId.isNotEmpty || value.bingeKey.isNotEmpty)) {
      throw const TedFailure('invalid_response');
    }
    return value;
  }
  Map<String, dynamic> toJson() => {'provider': provider, 'addon_id': addonId, 'binge_key': bingeKey};
  String? match(TedSourcePage page) {
    if (provider != 'stremio' || addonId.isEmpty || bingeKey.isEmpty) return null;
    final matches = page.choices.where((c) => c.addonId == addonId && c.bingeKey == bingeKey);
    return matches.length == 1 ? matches.single.id : null;
  }
}
