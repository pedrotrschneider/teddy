import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../utils/initials_palette.dart';

class TedProfileAvatar extends StatelessWidget {
  final String name;
  final Uint8List? image;
  final double diameter;
  const TedProfileAvatar({super.key, required this.name, this.image, required this.diameter});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest.shortestSide.clamp(0.0, diameter);
      final fallback = ColoredBox(
        color: colorForName(name, Theme.of(context)),
        child: Center(
          child: Text(
            initialOf(name),
            style: TextStyle(fontSize: size * .38, color: Colors.white, fontWeight: FontWeight.w500),
          ),
        ),
      );
      return ExcludeSemantics(
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: SizedBox.square(
            dimension: size,
            child: ClipOval(
              child: image == null
                  ? fallback
                  : Image.memory(image!, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => fallback),
            ),
          ),
        ),
      );
    },
  );
}
