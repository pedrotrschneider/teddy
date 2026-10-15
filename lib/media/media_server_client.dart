import '../exceptions/media_server_exceptions.dart';
import '../media/media_source_info.dart';
import '../media/media_sort.dart';
import '../services/api_cache.dart';
import '../services/playback_initialization_types.dart';
import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart' show AbortController, MediaServerResponse, throwIfHttpError;
import '../utils/external_ids.dart';
import '../utils/watch_state_notifier.dart';
import 'artist_discography.dart';
import 'download_resolution.dart';
import 'ids.dart';
import 'library_filter_result.dart';
import 'library_change_event.dart';
import 'library_query.dart';
import 'live_tv_support.dart';
import 'lyrics.dart';
import 'media_backend.dart';
import 'media_file_info.dart';
import 'media_hub.dart';
import '../services/scrub_preview_source.dart';
import 'media_item.dart';
import 'media_kind.dart';
import 'media_library.dart';
import 'media_person.dart';
import 'media_playlist.dart';
import 'playback_report_metadata.dart';
import 'server_capabilities.dart';

/// Default number of items requested for horizontal hub previews.
const int defaultHubPreviewLimit = 20;

/// Default number of people [MediaServerClient.searchPeople] returns.
const int defaultPeopleSearchLimit = 20;

/// One collection holding some of the items asked about in
/// [MediaServerClient.fetchCollectionMemberships], with those items' ids in
/// the collection's own order.
typedef CollectionMembership = ({MediaItem collection, List<String> memberIds});


/// Outcome of a health probe. Distinguishes the two refusals a reachable
/// server can answer with from a generic transport failure, so the manager can
/// route each to its own UI: [authError] (HTTP 401 — the token was rejected;
/// "Sign in again"), [accessDenied] (HTTP 403 — the server knows the account
/// and refuses it; a new sign-in changes nothing), and [offline].
enum HealthStatus { online, offline, authError, accessDenied }

abstract interface class GracefullyCloseable {
  Future<void> closeGracefully({Duration drainTimeout});
}

/// Per-leg outcome sink for hub fetches.
///
/// Home rows are best-effort by design: a hub leg that fails degrades to an
/// empty list rather than sinking the screen. That makes "this server has no
/// rows" and "every row request failed" indistinguishable at the aggregation
/// boundary, so a totally failed refresh was reported to the user as a
/// success (#1829).
///
/// Callers that need to tell them apart pass a sink and the backend records
/// each leg it degraded. A sink rather than a widened return type keeps every
/// existing caller untouched, and lets a response carry *partial* rows
/// alongside a failure — which throwing cannot.
///
/// Deliberately not recorded: legs whose degradation is intentional rather
/// than a fault, i.e. Emby's series-reconstruction deadline and its
/// per-series probes.
class HubFetchDiagnostics {
  var _failed = false;
  var _cancelled = false;

  /// A leg failed for a reason that is not a client-side abort.
  bool get failed => _failed;

  /// A leg was aborted client-side. Cancellation is not failure: a disrupted
  /// pass says nothing about the server's actual content.
  bool get cancelled => _cancelled;

  void recordFailure(Object error) {
    if (error is MediaServerHttpException && error.isCancellation) {
      _cancelled = true;
    } else {
      _failed = true;
    }
  }
}

abstract class MediaServerClient {
  ServerId get serverId;
  String? get serverName;
  MediaBackend get backend;
  ServerCapabilities get capabilities;

  /// Opaque identity of the committed authentication session, independent of
  /// the endpoint. Compare by identity: successful effective credential or
  /// profile changes install a fresh identity; failed and no-op updates do not.
  Object get authenticationSessionId;

  /// Release HTTP resources and any other long-lived state. Idempotent.
  void close();

  /// Open a fresh push channel for this server's library-change
  /// notifications, or `null` when the backend has none wired
  /// ([ServerCapabilities.libraryChangeEvents]). The caller owns the returned
  /// channel's start/stop/dispose lifecycle — `LibraryEventService` in
  /// production.
  LibraryEventChannel? createLibraryEventChannel() => null;

  /// Probe the server with a lightweight auth-required round-trip and
  /// classify the outcome. Implementations must surface 401 as
  /// [HealthStatus.authError] and 403 as [HealthStatus.accessDenied] so the
  /// manager can flag a revoked token and a refused account distinctly from a
  /// generic network failure.
  Future<HealthStatus> checkHealth();

  Future<String?> getMachineIdentifier();

  /// When `true`, the client serves cached responses only and never hits the
  /// network.
  bool get isOfflineMode;
  void setOfflineMode(bool offline);

  /// Backend-specific cache substrate. Subclasses override this so the
  /// shared [MediaServerCacheMixin] helpers can read and write through the
  /// appropriate cache instance.
  ApiCache get cache;

  Future<List<MediaLibrary>> fetchLibraries();

  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  });

  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind});

  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType});

  Future<void> refreshLibraryMetadata(String libraryId);

  /// Fetch a single item by its backend-opaque id. An online HTTP 404 returns
  /// `null`; every other HTTP status remains an error. Implementations may use
  /// cached metadata while explicitly offline or after a classified transient
  /// transport failure, but must not turn other online failures into stale
  /// success.
  Future<MediaItem?> fetchItem(String id);

  /// Fetch a single item *and* its on-deck episode (the next unwatched /
  /// in-progress episode). The item follows [fetchItem]'s error contract: an
  /// online HTTP 404 returns both nullable fields as `null`, while every other
  /// HTTP status throws.
  ///
  /// Some implementations require several requests that the detail screen
  /// does not need to wait for before painting.
  ///
  /// [onItemReady] exists for exactly that case: implementations invoke it as
  /// soon as the item is known, *if* that is strictly before the full lookup
  /// settles. Backends that resolve everything in one round trip never invoke
  /// it, and neither does a null item. Callers must therefore treat it as an
  /// optional early paint and still handle the returned record.
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  });

  /// Direct children of [parentId] — episodes of a season, seasons of a
  /// show, tracks of an album, items of a collection.
  Future<List<MediaItem>> fetchChildren(String parentId);

  Future<List<MediaItem>> fetchLibraryFolders(String libraryId, {void Function(List<MediaItem> itemsSoFar)? onPage});

  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  });

  /// Page through direct children of [parentId]. Unlike
  /// [fetchPlayableDescendantsPage], this preserves container shape and is used
  /// for large season episode lists where the children endpoint is the correct
  /// backend primitive.
  Future<LibraryPage<MediaItem>> fetchChildrenPage(String parentId, {int? start, int? size, AbortController? abort});

  /// Page through playable descendants of [parentId]. Used by flattened show /
  /// season detail views so episodes can render before the full list has loaded.
  /// [fetchPlayableDescendants] remains the complete-list helper for
  /// playback/download/sync paths.
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  });

  Future<List<MediaItem>> fetchPlayableDescendants(String parentId);

  /// All episodes of a series across every season in playback order. Used
  /// to build a local navigation queue for backends without server-side
  /// queues and as a fallback when a server-side queue could not be created.
  /// Returns null only when a backend cannot supply a client-side queue;
  /// an empty list means the series itself was empty.
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId);

  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist);

  Future<List<ArtistDiscographyGroup>> fetchArtistDiscography(MediaItem artist);

  Future<List<MediaItem>> fetchAlbumTracks(String albumId);

  Future<List<MediaItem>> fetchInstantMix(String itemId, {int limit = 100});

  Future<Lyrics?> fetchLyrics(MediaItem track);

  /// Free-text search across the user's libraries. [limit] is a per-request
  /// candidate budget; a backend may supplement omitted media categories and
  /// return more candidates for cross-server ranking. [abort] cancels every
  /// backend request owned by this search pass.
  ///
  /// [excludedLibraryIds] names server-local libraries the user has hidden. A
  /// backend whose search rows carry a library id may ignore it, because the
  /// caller drops those rows by id. A backend whose rows cannot be attributed
  /// to a library MUST scope the request server-side instead — the caller has
  /// nothing to filter on.
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  });

  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  });

  /// Items the user has started but not finished. Plex calls this "On Deck"
  /// internally; the neutral name matches the Continue Watching UI surface.
  ///
  /// [excludedLibraryIds] names server-local libraries the user has hidden,
  /// with the same contract as in [searchItems]: a backend whose rows carry a
  /// library id may ignore it, and one whose rows cannot be attributed to a
  /// library MUST leave those libraries out itself.
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}});

  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  });

  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  });

  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10});

  /// Playable extras attached to [id] (trailers, featurettes, deleted scenes,
  /// behind-the-scenes clips). Backends return only items that can be opened by
  /// the normal video playback flow; external/remote trailer URLs are out of
  /// scope for this neutral surface.
  Future<List<MediaItem>> fetchExtras(String id);

  /// Page through media featuring a specific person/actor.
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(String personId, {int? start, int? size, AbortController? abort});

  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit});

  /// Page through expanded hub content where the backend exposes a paged
  /// endpoint. Backends without true hub pagination may return a single page.
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(String hubId, {int? start, int? size, AbortController? abort});

  /// Mark [item] as watched. Transport only: no [WatchStateEvent] is emitted
  /// here — UI surfaces go through `WatchActions`, which owns the single
  /// emission (and tracker fan-out); the offline sync replay calls this
  /// directly precisely because the event already fired when the action was
  /// queued.
  ///
  /// Postcondition: once this completes the backend must no longer treat
  /// [item] as resumable, so it cannot come back from [fetchContinueWatching].
  /// Plex gets this for free (PMS filters watched items out of its on-deck
  /// hub). MediaBrowser derives Continue Watching membership purely from
  /// `UserData.PlaybackPositionTicks > 0`, so its implementation must ensure
  /// the resume position is cleared rather than assume the played flag did it
  /// (#1812).
  Future<void> markWatched(MediaItem item);

  /// Mark [item] as unwatched. Transport only — see [markWatched].
  Future<void> markUnwatched(MediaItem item);

  /// Hide an item from Continue Watching without changing watched status or
  /// progress. Only call when [capabilities.continueWatchingRemoval] is true;
  /// unsupported backends throw [UnsupportedError].
  Future<void> removeFromContinueWatching(MediaItem item);

  Future<void> rate(MediaItem item, double rating);

  /// Set or clear the per-user favorite flag ("heart") for [item]. Only call
  /// when [ServerCapabilities.userFavorites] is true; unsupported backends
  /// throw [UnsupportedError]. Throws [MediaServerHttpException] on failure.
  Future<void> setFavorite(MediaItem item, bool isFavorite);

  /// Page through server playlists. Used by the library Playlists tab so large
  /// servers can render incrementally.
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  });

  /// Metadata only — items are fetched via [fetchPlaylistPage].
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id);

  /// Page through items in [id]. Backends preserve playlist order and include
  /// per-playlist item ids where the server exposes them.
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort});

  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items});

  /// Append [items] to an existing playlist. Returns `true` on success.
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items});

  /// Delete [playlist] from the server. Returns `true` on success.
  Future<bool> deletePlaylist(MediaPlaylist playlist);

  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  });

  /// Remove [item] from the playlist [playlistId]. See [movePlaylistItem] for
  /// the same caveats about backend tagging and the per-playlist id.
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item});

  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  });

  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  });

  Future<List<CollectionMembership>> fetchCollectionMemberships(Set<String> itemIds, {AbortController? abort});

  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  });

  /// Append [items] to an existing collection.
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items});

  /// Remove a single [item] from [collectionId].
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item});

  /// Delete a collection from the server. The collection is passed as a
  /// [MediaItem] (kind == [MediaKind.collection]) so the implementation can
  /// read [MediaItem.libraryId] for backends that need it (Plex).
  Future<bool> deleteCollection(MediaItem collection);

  /// Permanently delete [item] from the library.
  Future<bool> deleteMediaItem(MediaItem item);

  Future<MediaFileInfo?> getFileInfo(MediaItem item);

  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true});

  String externalImageUrl(String url, {int? width, int? height, bool cover = true});

  Map<String, String> get streamHeaders;

  Future<ExternalIds> fetchExternalIds(String itemId);

  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  });

  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  });

  /// Cache-only [PlaybackExtras] read for [itemId]. Used as the offline
  /// fallback when [fetchPlaybackExtras] cannot reach the network. Returns
  /// `null` when no row is cached or the row carries no chapter/marker
  /// data — callers treat that as "no extras available" without surfacing
  /// an error.
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  });

  /// Cache-only [MediaSourceInfo] read for [itemId]. Used by the offline
  /// playback path to recover audio/subtitle track info (track ids, language
  /// codes, displayTitles) without hitting the network. Returns `null` when
  /// the row isn't cached or carries no usable media source.
  /// Uses playback's source-selection order: stable [mediaSourceId], then a
  /// sibling [preferredVersionSignature], then [mediaIndex], subject to the
  /// backend's playable-source rules.
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(
    String itemId, {
    int mediaIndex = 0,
    String? mediaSourceId,
    String? preferredVersionSignature,
  });

  Future<ScrubPreviewSource?> createScrubPreviewSource({required MediaItem item, required MediaSourceInfo mediaSource});

  double get watchedThreshold;

  bool get marksWatchedOnPlaybackStopped;

  Future<void> reportPlaybackStarted({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  });

  Future<void> reportPlaybackProgress({
    required String itemId,
    required Duration position,
    required Duration duration,
    bool isPaused = false,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  });

  Future<void> reportPlaybackStopped({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    PlaybackReportMetadata report = const PlaybackReportMetadata.live(),
  });

  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options);

  /// Backend-neutral live-TV operations. Always returns a wrapper; consult
  /// [LiveTvSupport.isAvailable] to find out whether the server actually
  /// has live TV configured before calling other methods. Recording and DVR
  /// administration are available through [MediaServerClientLiveTv.liveTvDvr].
  LiveTvSupport get liveTv;

  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId});

  Future<MediaItem> stampLibrary(MediaItem item);

  /// The artwork files the download pipeline should persist for [item] so
  /// the offline UI can render its poster, clear logo, and background art.
  /// Each entry pairs the absolute URL with a stable `localKey` the
  /// storage service hashes to deduplicate across items that share blobs.
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item);

  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  });
}

/// Optional interface for backends whose public server id is not specific
/// enough for user-scoped local state.
abstract interface class ScopedMediaServerClient {
  String get scopedServerId;
}

extension MediaServerClientScope on MediaServerClient {
  String get cacheServerId => switch (this) {
    ScopedMediaServerClient(:final scopedServerId) => scopedServerId,
    _ => serverId,
  };

  Future<void> markWatchedFromPlaybackStop(MediaItem item) async {
    final performedExplicitMark = !marksWatchedOnPlaybackStopped;
    if (performedExplicitMark) {
      await markWatched(item);
    }
    WatchStateNotifier().notifyWatched(
      item: item,
      isNowWatched: true,
      cacheServerId: cacheServerId,
      // A successful report cannot prove that the backend marked the item
      // played; only the explicit mutation settles this patch.
      serverAcknowledged: performedExplicitMark,
    );
  }

  WatchPatchId? notifyWatchedFromPlaybackSession(MediaItem item) {
    return WatchStateNotifier().notifyWatched(
      item: item,
      isNowWatched: true,
      cacheServerId: cacheServerId,
      serverAcknowledged: false,
    );
  }
}

extension MediaServerClientLiveTv on MediaServerClient {
  /// Optional recording/admin adapter, gated by the backend capability flag.
  /// Call sites use this rather than assuming every Live TV backend supports
  /// Plex's DVR surface.
  LiveTvDvrSupport? get liveTvDvr => capabilities.liveTvDvr ? liveTv.dvr : null;
}

abstract interface class SeasonEpisodePagingClient {
  Future<LibraryPage<MediaItem>> fetchSeasonEpisodesPage(
    String seriesId,
    String seasonId, {
    int? start,
    int? size,
    AbortController? abort,
  });
}

abstract interface class MediaDeletionPermissionClient {
  /// `true`/`false` as reported by the server for [item], or `null` when the
  /// server did not answer (item not visible to this user, unexpected shape).
  ///
  /// Never served from cache: the answer changes server-side with no
  /// client-visible event, and a stale `true` puts a destructive action back in
  /// front of a user who lost the grant. Callers must fail closed on `null`
  /// and on throw.
  Future<bool?> fetchDeletePermission(MediaItem item);
}

/// Bounds how old a cached metadata row may be to be served without a network
/// round trip on playback start. Sized to cover the detail-screen-visit →
/// play-tap gap while keeping stale-file risk (replaced/deleted media parts)
/// negligible.
const Duration playbackMetadataCacheFreshness = Duration(minutes: 5);

mixin MediaServerCacheMixin implements MediaServerClient {
  /// Fetch with cache fallback: offline → cached only; online → try network,
  /// cache the result, then fall back to cached data on an accepted error.
  ///
  /// When [shouldFallback] is omitted, every error remains eligible for cache
  /// fallback. A supplied selector narrows that policy; rejected errors are
  /// rethrown unchanged before the fallback cache is read. Response-parser
  /// failures can therefore be propagated instead of hidden by stale data.
  ///
  /// Returns `null` when offline mode is on and no cached row exists, or
  /// when both network and cache come up empty.
  ///
  /// Pass [cacheScope] when the caller already snapshotted a request context
  /// (see [fetchWithCacheFirst]); otherwise the live profile is sampled, which
  /// is only safe when nothing has awaited since the call began.
  Future<T?> fetchWithCacheFallback<T>({
    required String cacheKey,
    required Future<MediaServerResponse> Function() networkCall,
    required T? Function(dynamic cachedData) parseCache,
    required T? Function(MediaServerResponse response) parseResponse,
    bool Function(Object error)? shouldFallback,
    bool cacheResponse = true,
    ServerId? cacheScope,
  }) async {
    final scope = cacheScope ?? ServerId(cacheServerId);
    if (isOfflineMode) {
      final cached = await cache.get(scope, cacheKey);
      if (cached != null) return parseCache(cached);
      return null;
    }
    try {
      final response = await networkCall();
      throwIfHttpError(response);
      final parsed = parseResponse(response);
      if (cacheResponse) {
        await _putCacheResponse(scope, cacheKey, response.data);
      }
      return parsed;
    } catch (e) {
      if (shouldFallback != null && !shouldFallback(e)) rethrow;
      appLogger.w('Network request failed for $cacheKey, trying cache', error: e);
      final cached = await cache.get(scope, cacheKey);
      if (cached != null) return parseCache(cached);
      rethrow;
    }
  }

  /// Cache-first fetch: serve from cache when available, hit the network
  /// only on miss. Use when freshness is non-critical and prior fetches are
  /// likely to have populated the cache (e.g. playback after the detail
  /// screen pre-warmed the row).
  ///
  /// [cacheScope] must be captured from the same request context as
  /// [networkCall]. The cache lookup may yield before a miss is known, so
  /// sampling a live profile inside [networkCall] can cross profile identities.
  Future<T?> fetchWithCacheFirst<T>({
    required ServerId cacheScope,
    required String cacheKey,
    required Future<MediaServerResponse> Function() networkCall,
    required T? Function(dynamic cachedData) parseCache,
    required T? Function(MediaServerResponse response) parseResponse,
    bool cacheResponse = true,
  }) async {
    final cached = await cache.get(cacheScope, cacheKey);
    if (cached != null) return parseCache(cached);
    if (isOfflineMode) return null;
    final response = await networkCall();
    throwIfHttpError(response);
    final parsed = parseResponse(response);
    if (cacheResponse) {
      await _putCacheResponse(cacheScope, cacheKey, response.data);
    }
    return parsed;
  }

  Future<void> _putCacheResponse(ServerId cacheScope, String cacheKey, dynamic data) async {
    try {
      if (data is Map<String, dynamic>) {
        await cache.put(cacheScope, cacheKey, data);
      } else if (data != null) {
        appLogger.w('Unexpected response type for $cacheKey: ${data.runtimeType}');
      }
    } catch (e, st) {
      appLogger.w('Cache write failed for $cacheKey', error: e, stackTrace: st);
    }
  }
}
