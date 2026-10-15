import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../media/media_backend.dart';

class BackendBadge extends StatelessWidget {
  final MediaBackend backend;
  final double size;
  final Color? color;

  const BackendBadge({super.key, required this.backend, this.size = 16, this.color});

  @override
  Widget build(BuildContext context) {
    final tint =
        color ??
        DefaultTextStyle.of(context).style.color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    if (backend == MediaBackend.ted) return Icon(Icons.movie_outlined, size: size, color: tint);
    final asset = switch (backend) {
      MediaBackend.plex => 'assets/plex_chevron.svg',
      MediaBackend.ted => throw StateError('TED uses its native icon'),
    };
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      theme: SvgTheme(currentColor: tint),
    );
  }
}
