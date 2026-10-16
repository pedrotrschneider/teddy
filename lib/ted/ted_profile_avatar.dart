import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../utils/initials_palette.dart';

class TedProfileAvatar extends StatelessWidget {
  final String name;
  final Uint8List? image;
  final double diameter;
  const TedProfileAvatar({super.key, required this.name, this.image, required this.diameter});

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: colorForName(name, Theme.of(context)),
      child: Center(
        child: Text(
          initialOf(name),
          style: TextStyle(fontSize: diameter * .38, color: Colors.white, fontWeight: FontWeight.w500),
        ),
      ),
    );
    return ExcludeSemantics(
      child: ClipOval(
        child: SizedBox.square(
          dimension: diameter,
          child: image == null
              ? fallback
              : Image.memory(image!, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => fallback),
        ),
      ),
    );
  }
}
