library;

class DownloadSubtitleSpec {
  final int id;
  final String url;
  final String? codec;
  final String? language;
  final String? languageCode;
  final bool forced;
  final String? displayTitle;

  const DownloadSubtitleSpec({
    required this.id,
    required this.url,
    this.codec,
    this.language,
    this.languageCode,
    this.forced = false,
    this.displayTitle,
  });
}

class DownloadArtworkSpec {
  final String localKey;
  final String url;

  const DownloadArtworkSpec({required this.localKey, required this.url});
}

/// A file after the first of an item stacked across several files (Plex
/// `Part 2`, `Part 3`), with the subtitle sidecars that belong to that file.
class DownloadPartResolution {
  final String url;
  final List<DownloadSubtitleSpec> externalSubtitles;

  const DownloadPartResolution({required this.url, this.externalSubtitles = const []});
}

/// Bundle of everything the download pipeline needs to fetch the primary
/// video file and its companion subtitle sidecars for a chosen media
/// version.
class DownloadResolution {
  /// The first (for most items the only) file.
  final String? videoUrl;
  final String? mediaSourceId;
  final List<DownloadSubtitleSpec> externalSubtitles;

  /// Whether [externalSubtitles] is authoritative. A false value keeps the
  /// supplementary-download queue pending so it can retry enrichment later.
  final bool externalSubtitlesResolved;

  /// The files after [videoUrl], in playback order, when the version is
  /// stacked across several files. Empty for a single-file version.
  final List<DownloadPartResolution> additionalParts;

  const DownloadResolution({
    required this.videoUrl,
    this.mediaSourceId,
    this.externalSubtitles = const [],
    this.externalSubtitlesResolved = true,
    this.additionalParts = const [],
  });
}
