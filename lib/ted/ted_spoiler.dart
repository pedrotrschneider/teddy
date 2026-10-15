import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../widgets/settings_builder.dart';

class TedSpoiler extends StatelessWidget {
  final bool unwatchedEpisode;
  final Widget child;
  const TedSpoiler({super.key, required this.unwatchedEpisode, required this.child});
  @override
  Widget build(BuildContext context) => SettingValueBuilder(
    pref: SettingsService.hideSpoilers,
    builder: (_, hidden, _) => hidden && unwatchedEpisode
        ? ExcludeSemantics(
            child: ClipRect(
              child: ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: child),
            ),
          )
        : child,
  );
}
