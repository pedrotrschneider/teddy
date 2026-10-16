import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../widgets/settings_builder.dart';

/// Lay out the entire navigator (including dialogs and player controls) in
/// scaled logical units. Keep the real device pixel ratio: native video is a
/// separate surface and must continue to cover the physical display at full
/// resolution. FittedBox also transforms pointer and focus geometry.
class TeddyUiScale extends StatelessWidget {
  final Widget child;
  const TeddyUiScale({super.key, required this.child});

  @override
  Widget build(BuildContext context) => SettingsBuilder(
    prefs: [SettingsService.teddyUiScalePercent],
    builder: (context) {
      final scale = SettingsService.instance.read(SettingsService.teddyUiScalePercent) / 100;
      final media = MediaQuery.of(context);
      return LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth / scale, constraints.maxHeight / scale);
          return FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: MediaQuery(
                data: media.copyWith(
                  size: size,
                  padding: media.padding / scale,
                  viewPadding: media.viewPadding / scale,
                  viewInsets: media.viewInsets / scale,
                  systemGestureInsets: media.systemGestureInsets / scale,
                ),
                child: child,
              ),
            ),
          );
        },
      );
    },
  );
}
