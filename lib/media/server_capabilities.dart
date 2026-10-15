class ServerCapabilities {
  /// This backend kind has a Live TV / DVR API the app can talk to. Whether
  /// a *specific* server has Live TV configured is a runtime concern —
  /// [MultiServerProvider.checkLiveTvAvailability] probes each server and
  /// only those with channels surface in [MultiServerProvider.liveTvServers].
  final bool liveTv;

  final bool liveTvDvr;

  /// Server can transcode video.
  final bool videoTranscoding;

  final bool richHubs;

  final bool numericUserRating;

  final bool userFavorites;

  final bool continueWatchingRemoval;

  /// External subtitle search/marketplace (Plex `/library/metadata/{id}/subtitles`).
  /// Hides the "Search subtitles" affordance when false.
  final bool externalSubtitleSearch;

  /// Server exposes metadata edit endpoints. Hides edit affordances when false.
  final bool richMetadataEdit;

  final bool scrubThumbnails;

  final bool folderGrouping;

  final bool instantMix;

  final bool libraryChangeEvents;

  const ServerCapabilities({
    this.liveTv = false,
    this.liveTvDvr = false,
    this.videoTranscoding = true,
    this.richHubs = false,
    this.numericUserRating = false,
    this.userFavorites = false,
    this.continueWatchingRemoval = false,
    this.externalSubtitleSearch = false,
    this.richMetadataEdit = false,
    this.scrubThumbnails = false,
    this.folderGrouping = false,
    this.instantMix = false,
    this.libraryChangeEvents = false,
  });

  /// Defaults for a fully-featured Plex server.
  static const ServerCapabilities plex = ServerCapabilities(
    liveTv: true,
    liveTvDvr: true,
    videoTranscoding: true,
    richHubs: true,
    numericUserRating: true,
    userFavorites: false,
    continueWatchingRemoval: true,
    externalSubtitleSearch: true,
    richMetadataEdit: true,
    scrubThumbnails: true,
    folderGrouping: true,
    instantMix: true,
    libraryChangeEvents: true,
  );

  /// Every flag here is fixed per backend *kind* except [videoTranscoding],
  /// which Plex probes per server (`PlexClient.capabilities`) — so that is the
  /// only override this type needs. Widen the parameter list if another flag
  /// ever becomes a runtime probe.
  ServerCapabilities copyWith({bool? videoTranscoding}) {
    return ServerCapabilities(
      liveTv: liveTv,
      liveTvDvr: liveTvDvr,
      videoTranscoding: videoTranscoding ?? this.videoTranscoding,
      richHubs: richHubs,
      numericUserRating: numericUserRating,
      userFavorites: userFavorites,
      continueWatchingRemoval: continueWatchingRemoval,
      externalSubtitleSearch: externalSubtitleSearch,
      richMetadataEdit: richMetadataEdit,
      scrubThumbnails: scrubThumbnails,
      folderGrouping: folderGrouping,
      instantMix: instantMix,
      libraryChangeEvents: libraryChangeEvents,
    );
  }
}
