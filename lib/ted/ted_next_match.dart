import '../models/next_episode_matching_strategy.dart';
import 'ted_models.dart';
import 'ted_source_models.dart';

/// Matches releases within an explicitly fetched successor, never media IDs.
TedSourceChoice? matchNextRelease(
  TedPlaybackSession current,
  TedSourcePage next,
  NextEpisodeMatchingStrategy strategy, {
  TedSourceChoice? origin,
}) {
  if (strategy == NextEpisodeMatchingStrategy.manual || current.source != 'addon' || current.addonId.isEmpty) {
    return null;
  }
  final candidates = next.choices.where((c) => c.addonId == current.addonId && c.rdDirectPlay).toList();
  TedSourceChoice? unique(bool Function(TedSourceChoice) accepts) {
    final matches = candidates.where(accepts).toList();
    return matches.length == 1 ? matches.single : null;
  }

  if (current.bingeKey.isNotEmpty) {
    final grouped = candidates.where((c) => c.bingeKey == current.bingeKey).toList();
    if (grouped.isNotEmpty) return grouped.length == 1 ? grouped.single : null;
  }
  if (strategy != NextEpisodeMatchingStrategy.bestGuess || origin == null || origin.addonId != current.addonId) {
    return null;
  }
  if (origin.packKey.isNotEmpty) {
    final pack = candidates.where((c) => c.packKey == origin.packKey).toList();
    if (pack.isNotEmpty) return pack.length == 1 ? pack.single : null;
  }
  final signature = normalizedEpisodeRelease(origin);
  if (signature != null) {
    final named = candidates.where((c) => normalizedEpisodeRelease(c) == signature).toList();
    if (named.isNotEmpty) return named.length == 1 ? named.single : null;
  }
  final technical = releaseSignals(origin);
  double score(TedSourceChoice choice) {
    final other = releaseSignals(choice);
    var matches = 0.0;
    if (technical['cut'] != other['cut'] && (technical['cut'] != null || other['cut'] != null)) return -1;
    for (final entry in technical.entries) {
      final value = other[entry.key];
      if (value == null) continue;
      if (value != entry.value) return -1;
      matches++;
    }
    // Require video resolution, codec and audio format; generic quality labels
    // alone are insufficient to pick a different release automatically.
    if (!['resolution', 'video', 'audio'].every((key) => technical[key] != null && other[key] == technical[key])) {
      return -1;
    }
    final bitrate = declaredReleaseBitrate(origin), nextBitrate = declaredReleaseBitrate(choice);
    if (bitrate != null && nextBitrate != null) {
      matches += (0.5 - (nextBitrate / bitrate - 1).abs()).clamp(0.0, 0.5);
    }
    return matches;
  }

  final ranked = candidates.map((c) => (choice: c, score: score(c))).where((c) => c.score >= 3).toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  if (ranked.isEmpty || ranked.length > 1 && ranked.first.score - ranked[1].score < 2) return null;
  return unique((c) => c.id == ranked.first.choice.id);
}

String? normalizedEpisodeRelease(TedSourceChoice choice) {
  final name = choice.fileName.isNotEmpty ? choice.fileName : choice.description.split('\n').first;
  final episode = RegExp(
    r'\bs\d{1,3}[ ._-]*e\d{1,4}\b|\b\d{1,3}x\d{1,4}\b|\bseason[ ._-]*\d{1,3}[ ._-]*episode[ ._-]*\d{1,4}\b',
    caseSensitive: false,
  );
  final separated = name.replaceAll('_', ' ');
  if (!episode.hasMatch(separated)) return null;
  final value = separated
      .toLowerCase()
      .replaceAll(episode, ' episode ')
      .replaceAll('+', ' plus ')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  return value.length >= 12 ? value : null;
}

Map<String, String> releaseSignals(TedSourceChoice choice) {
  final text = '${choice.fileName} ${choice.name} ${choice.description}'.toLowerCase();
  String? find(String pattern) =>
      RegExp(pattern, caseSensitive: false).firstMatch(text)?[0]?.replaceAll(RegExp(r'[ ._-]'), '');
  return {
    'resolution': ?find(r'\b(2160p|1080p|720p|480p)\b'),
    if (find(r'\b(av1|hevc|h[ ._-]?265|x265|avc|h[ ._-]?264|x264)\b') case final value?)
      'video': switch (value) {
        'h265' || 'x265' => 'hevc',
        'h264' || 'x264' => 'avc',
        _ => value,
      },
    if (find(
          r'\b(dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?hd|truehd|e[ ._-]?ac[ ._-]?3|ddp|dd\+|ac[ ._-]?3|aac|flac|dts)(?=$|[^a-z])',
        )
        case final value?)
      'audio': value == 'ddp' || value == 'dd+' ? 'eac3' : value,
    'channels': ?find(r'\b(7[.]1|5[.]1|2[.]0)\b'),
    if (find(r'\b(dovi|dolby[ ._-]?vision|dv|hdr10\+?|hdr|sdr)(?=$|[^a-z0-9])') case final value?)
      'range': switch (value) {
        'dovi' || 'dolbyvision' => 'dv',
        'hdr' => 'hdr10',
        _ => value,
      },
    'source': ?find(r'\b(web[ ._-]?dl|webrip|bluray|bdrip|hdtv|remux)\b'),
    'language': ?find(r'\b(english|japanese|french|german|spanish|portuguese|multi|dual)\b'),
    'cut': ?find(r'\b(extended|uncut|unrated|theatrical|directors?[ ._-]*cut|remastered)\b'),
    'year': ?find(r'\b(19[0-9]{2}|20[0-9]{2})\b'),
  };
}

double? declaredReleaseBitrate(TedSourceChoice choice) {
  final match = RegExp(
    r'\b(\d+(?:[.,]\d+)?)\s*(m|k)(?:bps|b/s|bit/s)\b',
    caseSensitive: false,
  ).firstMatch('${choice.fileName} ${choice.name} ${choice.description}');
  if (match == null) return null;
  final value = double.tryParse(match[1]!.replaceAll(',', '.'));
  if (value == null || !value.isFinite || value <= 0) return null;
  return value * (match[2]!.toLowerCase() == 'm' ? 1000000 : 1000);
}
