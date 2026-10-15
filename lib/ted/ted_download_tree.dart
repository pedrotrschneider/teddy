import 'dart:io';
import 'package:path/path.dart' as p;
import 'ted_downloads.dart';
import 'ted_models.dart';
import 'ted_download_watch.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';

class TedDownloadNode {
  final String id, kind, title;
  final int depth;
  final List<TedDownloadNode> children;
  final Map<String, dynamic>? saved, queued;
  final TedMediaIdentity? media;
  int bytes;
  String? artwork;
  bool watched = false;
  bool currentlyWatched = false;
  int downloaded = 0, completed = 0, positionMs = 0;
  int? durationMs;
  MediaItem get indicatorItem => MediaItem.ted(
    id: id,
    kind: kind == 'show'
        ? MediaKind.show
        : kind == 'season'
        ? MediaKind.season
        : kind == 'movie'
        ? MediaKind.movie
        : MediaKind.episode,
    title: title,
    viewCount: watched ? 1 : 0,
    viewOffsetMs: positionMs,
    durationMs: durationMs,
    leafCount: expandable ? downloaded : null,
    viewedLeafCount: expandable ? completed : null,
  );
  TedDownloadNode(
    this.id,
    this.kind,
    this.title,
    this.depth, {
    this.saved,
    this.queued,
    this.media,
    this.bytes = 0,
    this.artwork,
    List<TedDownloadNode>? children,
  }) : children = children ?? [];
  Set<TedMediaIdentity> get identities => {?media, for (final child in children) ...child.identities};
  bool get expandable => kind == 'show' || kind == 'season';
  bool get hasFailures =>
      saved?['status'] == 'failed' || queued?['status'] == 'failed' || children.any((c) => c.hasFailures);
  Set<TedMediaIdentity> get failedIdentities => {
    if (hasFailures && media != null) media!,
    for (final child in children) ...child.failedIdentities,
  };
}

/// Group only by TED's canonical IDs; names and artwork never decide identity.
List<TedDownloadNode> tedDownloadTree(
  TedDownloads downloads,
  List<Map<String, dynamic>> saved,
  List<Map<String, dynamic>> queued,
  Map<String, int> sizes, {
  Map<TedMediaIdentity, TedDownloadWatch> watches = const {},
}) {
  final roots = <String, TedDownloadNode>{};
  final prepared = {
    for (final value in saved) TedMediaIdentity.fromJson(Map<String, dynamic>.from(value['media'] as Map)): value,
  };
  final intents = {
    for (final value in queued) TedMediaIdentity.fromJson(Map<String, dynamic>.from(value['media'] as Map)): value,
  };
  for (final media in {...prepared.keys, ...intents.keys}) {
    final file = prepared[media], intent = intents[media];
    final metadata = file == null ? (intent?['metadata'] as Map?) : downloads.metadata(file).toJson();
    final title = metadata?['title'] as String? ?? (intent?['name'] as String? ?? media.id);
    final leaf = TedDownloadNode(
      media.id,
      media.kind,
      title,
      media.kind == 'movie' ? 0 : 2,
      saved: file,
      queued: intent,
      media: media,
      bytes: file == null ? 0 : sizes[file['id']] ?? 0,
    );
    String? art(String name) {
      if (file == null) return null;
      final path = p.join(downloads.directory(file['id'] as String).path, '$name.image');
      return File(path).existsSync() ? path : null;
    }

    leaf.artwork = art('poster');
    if (media.kind == 'episode') leaf.artwork = art('thumbnail') ?? leaf.artwork;
    final watch = watches[media];
    leaf.currentlyWatched = watch?.played == true;
    if (file?['status'] == 'complete') {
      final at = DateTime.tryParse(file?['downloaded_at'] as String? ?? '');
      leaf.downloaded = at == null ? 0 : 1;
      leaf.watched = watch?.watchedAfter(at) ?? false;
      leaf.completed = leaf.watched ? 1 : 0;
      if (watch?.inProgress == true) {
        leaf.positionMs = watch!.positionMs;
        leaf.durationMs = watch.durationMs;
      }
    }
    if (media.kind == 'movie') {
      roots[media.id] = leaf;
      continue;
    }
    final parts = media.id.split(':');
    final show = roots.putIfAbsent(
      parts[0],
      () => TedDownloadNode(
        parts[0],
        'show',
        metadata?['grandparentTitle'] as String? ?? (intent?['name'] as String? ?? parts[0]).split(' · ').first,
        0,
      ),
    );
    show.artwork ??= art('show');
    final seasonId = '${parts[0]}:${parts[1]}';
    var season = show.children.where((v) => v.id == seasonId).firstOrNull;
    if (season == null) {
      season = TedDownloadNode(seasonId, 'season', parts[1] == '0' ? 'Specials' : 'Season ${parts[1]}', 1);
      show.children.add(season);
    }
    season.artwork ??= art('season');
    season.children.add(leaf);
    season.downloaded += leaf.downloaded;
    season.completed += leaf.completed;
    show.downloaded += leaf.downloaded;
    show.completed += leaf.completed;
    season.bytes += leaf.bytes;
    show.bytes += leaf.bytes;
  }
  for (final show in roots.values.where((v) => v.kind == 'show')) {
    show.children.sort((a, b) => int.parse(a.id.split(':')[1]).compareTo(int.parse(b.id.split(':')[1])));
    for (final season in show.children) {
      season.watched = season.downloaded > 0 && season.completed == season.downloaded;
      season.artwork ??= show.artwork;
      season.children.sort((a, b) => int.parse(a.id.split(':')[2]).compareTo(int.parse(b.id.split(':')[2])));
    }
    show.watched = show.downloaded > 0 && show.completed == show.downloaded;
  }
  return roots.values.toList()..sort((a, b) {
    final order = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return order == 0 ? a.id.compareTo(b.id) : order;
  });
}

String tedDiskSize(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}
