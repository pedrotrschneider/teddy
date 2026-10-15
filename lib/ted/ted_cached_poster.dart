import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../widgets/optimized_media_image.dart';
import 'ted_client.dart';
import 'ted_metadata_models.dart';

/// Use existing TED artwork without requesting descriptive/provider enrichment.
/// The authenticated bytes replace Cinemeta only after a successful first frame.
class TedCachedPoster extends StatefulWidget {
  final TedClient client;
  final TedMetadataAsset asset;
  final String fallback;
  final double? width, height;
  const TedCachedPoster({
    super.key,
    required this.client,
    required this.asset,
    required this.fallback,
    this.width,
    this.height,
  });
  @override
  State<TedCachedPoster> createState() => _TedCachedPosterState();
}

class _TedCachedPosterState extends State<TedCachedPoster> {
  late Future<Uint8List?> _bytes;
  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  Future<Uint8List?> _load() async {
    try {
      return await widget.client.metadataImage(widget.asset.id);
    } catch (_) {
      return null;
    }
  }

  @override
  void didUpdateWidget(TedCachedPoster old) {
    super.didUpdateWidget(old);
    if (old.client != widget.client || old.asset.id != widget.asset.id || old.asset.tag != widget.asset.tag) {
      _bytes = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback() => OptimizedMediaImage.thumb(
      imagePath: widget.fallback.isEmpty ? null : widget.fallback,
      width: widget.width,
      height: widget.height,
    );
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return fallback();
        return Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          fit: BoxFit.cover,
          frameBuilder: (context, child, frame, sync) => frame == null && !sync ? fallback() : child,
          errorBuilder: (_, _, _) => fallback(),
        );
      },
    );
  }
}
