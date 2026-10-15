import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/optimized_media_image.dart';
import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_metadata_models.dart';
import 'ted_spoiler.dart';

typedef _ArtworkKey = (TedMediaIdentity, int, String);

/// Scoped to this browse surface. Only realized personal cards request artwork;
/// queued work coalesces and up to five workflows run at once. Private bytes never
/// enter Plezy's public disk cache or the serializable media item.
class TedPersonalArtwork {
  static const _concurrency = 5;
  final TedClient client;
  final bool loadEpisodeDetails;
  final (Uri?, int?) _scope;
  final _cache = <_ArtworkKey, Uint8List?>{};
  final _pending = <_ArtworkKey, Completer<Uint8List?>>{};
  final _queue = Queue<TedTitle>();
  int _active = 0, _bytes = 0;
  bool _disposed = false;
  TedPersonalArtwork(this.client, {this.loadEpisodeDetails = true}) : _scope = (client.auth.server, client.auth.userId);
  bool get valid => !_disposed && _scope == (client.auth.server, client.auth.userId);

  static TedMetadataAsset? _movieImage(TedMetadataSnapshot? snapshot) {
    if (snapshot?.type != 'Movie') return null;
    for (final type in ['Backdrop', 'Thumb', 'Primary']) {
      final images = snapshot!.images.where((image) => image.type == type).toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      if (images.isNotEmpty) return images.first;
    }
    return null;
  }

  _ArtworkKey _key(TedTitle title) => title.media.kind == 'movie'
      ? (title.media, title.enrichment?.generation ?? -1, _movieImage(title.enrichment)?.id ?? '')
      : (
          title.media,
          title.enrichment?.generation ?? -1,
          title.enrichment?.images.where((image) => image.type == 'Primary').firstOrNull?.id ?? '',
        );

  Future<Uint8List?> load(TedTitle title, {bool retry = false}) {
    if (!valid || !['episode', 'movie'].contains(title.media.kind)) return Future.value();
    if (title.media.kind == 'episode' && title.enrichment == null && !loadEpisodeDetails) return Future.value();
    // Movie cards consume existing enrichment, without fetching full metadata
    // for every title in a shelf. Cinemeta remains the immediate fallback.
    if (title.media.kind == 'movie' && _movieImage(title.enrichment) == null) return Future.value();
    final key = _key(title);
    if (retry) {
      _bytes -= _cache.remove(key)?.length ?? 0;
    }
    if (_cache.containsKey(key)) {
      final bytes = _cache.remove(key);
      _cache[key] = bytes;
      return Future.value(bytes);
    }
    if (_pending.containsKey(key)) return _pending[key]!.future;
    final completion = Completer<Uint8List?>();
    _pending[key] = completion;
    _queue.add(title);
    _pump();
    return completion.future;
  }

  void _pump() {
    while (valid && _active < _concurrency && _queue.isNotEmpty) {
      _active++;
      unawaited(_run(_queue.removeFirst()));
    }
  }

  Future<void> _run(TedTitle title) async {
    final key = _key(title);
    Uint8List? bytes;
    try {
      final detail = title.media.kind == 'episode' && title.enrichment == null
          ? await client.title(title.media)
          : title;
      if (detail.media != title.media) throw const TedFailure('invalid_response');
      var snapshot = detail.enrichment;
      for (
        var attempt = 0;
        valid &&
            loadEpisodeDetails &&
            snapshot != null &&
            snapshot.pending &&
            snapshot.images.every((image) => image.type != 'Primary') &&
            attempt < 20;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!valid) break;
        snapshot = await client.metadata(snapshot.id);
      }
      final image = title.media.kind == 'movie'
          ? _movieImage(snapshot)
          : snapshot?.type == 'Episode'
          ? snapshot!.images.where((image) => image.type == 'Primary').firstOrNull
          : null;
      if (valid) {
        if (image != null) {
          for (var attempt = 0; valid && attempt < 12; attempt++) {
            bytes = await client.metadataImage(image.id);
            if (bytes != null || !valid) break;
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
      }
    } catch (_) {
      // A provider failure stays a visible retryable thumbnail failure; it
      // cannot remove the personal entry or mutate its viewing state.
    } finally {
      if (valid) {
        _cache[key] = bytes;
        _bytes += bytes?.length ?? 0;
        while (_cache.length > 64 || _bytes > 20 * 1024 * 1024) {
          _bytes -= _cache.remove(_cache.keys.first)?.length ?? 0;
        }
      }
      _pending.remove(key)?.complete(valid ? bytes : null);
      _active--;
      _pump();
    }
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
    _bytes = 0;
    _queue.clear();
    for (final pending in _pending.values) {
      pending.complete(null);
    }
    _pending.clear();
  }
}

class TedPersonalThumbnail extends StatefulWidget {
  final TedPersonalArtwork artwork;
  final TedTitle title;
  final double? width, height;
  final bool protectSpoilers;
  const TedPersonalThumbnail({
    super.key,
    required this.artwork,
    required this.title,
    this.width,
    this.height,
    this.protectSpoilers = true,
  });
  @override
  State<TedPersonalThumbnail> createState() => _TedPersonalThumbnailState();
}

class _TedPersonalThumbnailState extends State<TedPersonalThumbnail> {
  Uint8List? _bytes;
  bool _loading = true;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(TedPersonalThumbnail old) {
    super.didUpdateWidget(old);
    if (old.artwork != widget.artwork ||
        old.title.media != widget.title.media ||
        widget.artwork._key(old.title) != widget.artwork._key(widget.title)) {
      _bytes = null;
      _loading = true;
      unawaited(_load());
    }
  }

  Future<void> _load({bool retry = false}) async {
    final generation = ++_generation, owner = widget.artwork;
    if (retry) setState(() => _loading = true);
    final bytes = await owner.load(widget.title, retry: retry);
    if (!mounted || generation != _generation || !owner.valid) return;
    setState(() {
      _bytes = bytes;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.artwork.valid ? _bytes : null;
    // Keep the same Cinemeta artwork the card used before enrichment. The
    // authenticated provider image replaces it only after its first frame.
    final movie = widget.title.media.kind == 'movie';
    final fallbackPath = movie
        ? widget.title.background.isNotEmpty
              ? widget.title.background
              : widget.title.poster
        : widget.title.episodePoster.isNotEmpty
        ? widget.title.episodePoster
        : widget.title.poster;
    final posterFallback = movie && widget.title.poster.isNotEmpty && widget.title.poster != fallbackPath;
    Widget fallback() => OptimizedMediaImage.thumb(
      imagePath: fallbackPath.isEmpty ? null : fallbackPath,
      width: widget.width,
      height: widget.height,
      errorWidget: posterFallback
          ? (_, _, _) =>
                OptimizedMediaImage.thumb(imagePath: widget.title.poster, width: widget.width, height: widget.height)
          : null,
    );
    return TedSpoiler(
      unwatchedEpisode: widget.protectSpoilers && widget.title.media.kind == 'episode' && !widget.title.played,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (available != null)
            Image.memory(
              available,
              fit: BoxFit.cover,
              cacheWidth: 1280,
              gaplessPlayback: false,
              frameBuilder: (_, child, frame, _) => frame == null ? fallback() : child,
              errorBuilder: (_, _, _) => fallback(),
            )
          else
            fallback(),
          if (_loading && available == null && fallbackPath.isEmpty)
            const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          else if (!_loading &&
              available == null &&
              (!movie || TedPersonalArtwork._movieImage(widget.title.enrichment) != null))
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: movie ? 'Retry movie thumbnail' : 'Retry episode thumbnail',
                onPressed: () => unawaited(_load(retry: true)),
                icon: const Icon(Icons.refresh),
              ),
            ),
        ],
      ),
    );
  }
}
