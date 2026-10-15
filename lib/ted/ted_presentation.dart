import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/server_capabilities.dart';
import 'ted_client.dart';

/// TED data at Plezy's presentation boundary. Tokens/source descriptors stay
/// with the existing clients; UI keys never depend on their current family.
class TedPresentation {
  final TedClient client;
  const TedPresentation(this.client);
  static const capabilities = ServerCapabilities(videoTranscoding: false, richHubs: true);
  String get scope => 'ted/${Uri.encodeComponent(client.auth.server.toString())}/user/${client.auth.userId}';
  MediaItem item(TedTitle title) => MediaItem.ted(
    id: '${title.media.kind}/${title.media.id}',
    serverId: scope,
    serverName: 'TED',
    kind: switch (title.media.kind) {
      'movie' => MediaKind.movie,
      'series' => MediaKind.show,
      _ => MediaKind.episode,
    },
    title: title.episodeName.isNotEmpty ? title.episodeName : title.name,
    summary: title.description,
    year: int.tryParse(title.year.split(RegExp(r'[^0-9]')).first),
    thumbPath: title.episodePoster.isNotEmpty ? title.episodePoster : title.poster,
    artPath: title.background.isEmpty ? null : title.background,
    clearLogoPath: title.logo,
    parentIndex: title.season,
    index: title.episode,
    grandparentId: title.parent == null ? null : 'series/${title.parent!.id}',
    grandparentTitle: title.seriesName.isEmpty ? null : title.seriesName,
    grandparentThumbPath: title.poster,
    grandparentArtPath: title.background.isEmpty ? null : title.background,
    durationMs: title.durationMs,
    viewOffsetMs: title.positionMs,
    viewCount: title.played ? 1 : 0,
    leafCount: title.episodeCount,
    viewedLeafCount: title.watchedEpisodeCount,
    rating: title.rating,
    raw: {'imdb_rating': title.rating, 'joint_watches': title.jointWatches.map((w) => w.toJson()).toList()},
    genres: title.genres,
  );
  MediaHub hub(TedHomeRow row) => MediaHub(
    id: row.id,
    title: rowName(row.id),
    type: 'mixed',
    items: row.titles.map(item).toList(),
    serverId: scope,
  );
  static String rowName(String id) => switch (id) {
    'continue-watching' => 'Continue Watching',
    'new-releases' => 'New Releases',
    'next-up' => 'Next Up',
    'popular-movie' => 'Popular Movies',
    'popular-series' => 'Popular Shows',
    'movie' => 'Movies',
    'series' => 'Shows',
    'mapped' => 'Mapped items',
    'search' => 'Search',
    'downloads' => 'Downloads',
    _ => 'Home',
  };
}
