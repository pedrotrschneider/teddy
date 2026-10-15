import 'dart:ui' show AppExitResponse;
import 'package:flutter/widgets.dart';
import '../utils/app_logger.dart';

/// One owner of normal application exit. Flutter must keep its engine alive
/// until the player, download/report producers and Drift isolate have closed.
class TedAppShutdown {
  final Future<void> Function() closeStorage;
  Future<void> Function()? stopPlayback;
  Future<void> Function()? stopServices;
  Future<void>? _shutdown;
  bool get closing => _shutdown != null;

  TedAppShutdown({required this.closeStorage});

  Future<AppExitResponse> requestExit({Future<void>? startup, Duration deadline = const Duration(seconds: 15)}) async {
    try {
      await (() async {
        await startup;
        await close();
      })().timeout(deadline);
      return AppExitResponse.exit;
    } catch (_) {
      // A timeout never cancels the underlying teardown or permits the engine
      // to destroy an open database. Subsequent requests join the same work.
      appLogger.w('Teddy shutdown did not finish; application exit was cancelled');
      return AppExitResponse.cancel;
    }
  }

  Future<void> close() => _shutdown ??= _close().catchError((Object error, StackTrace stack) {
    // Only a completed failure may be retried. A timed-out caller continues
    // sharing the still-running cleanup instead of starting another teardown.
    _shutdown = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _close() async {
    await stopPlayback?.call();
    await stopServices?.call();
    await closeStorage();
  }
}

class TedAppShutdownScope extends InheritedWidget {
  final TedAppShutdown shutdown;
  const TedAppShutdownScope({super.key, required this.shutdown, required super.child});

  static TedAppShutdown? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TedAppShutdownScope>()?.shutdown;

  @override
  bool updateShouldNotify(TedAppShutdownScope oldWidget) => shutdown != oldWidget.shutdown;
}
