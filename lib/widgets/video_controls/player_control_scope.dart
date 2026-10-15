import 'package:flutter/material.dart';

/// Presentation overrides for TED's platform player; upstream defaults stay 1:1.
class PlayerControlScale extends InheritedWidget {
  final double factor;
  const PlayerControlScale({super.key, required this.factor, required super.child});
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerControlScale>()?.factor ?? 1;
  @override
  bool updateShouldNotify(PlayerControlScale oldWidget) => factor != oldWidget.factor;
}

class PlayerTimelinePosition extends InheritedNotifier<ValueNotifier<Duration>> {
  final Duration? duration;
  const PlayerTimelinePosition({
    super.key,
    required ValueNotifier<Duration> position,
    this.duration,
    required super.child,
  }) : super(notifier: position);
  static Duration? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerTimelinePosition>()?.notifier?.value;
  static Duration? durationOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerTimelinePosition>()?.duration;
  @override
  bool updateShouldNotify(PlayerTimelinePosition oldWidget) =>
      super.updateShouldNotify(oldWidget) || duration != oldWidget.duration;
}
