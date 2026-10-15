import 'package:flutter/material.dart';
import '../focus/key_event_utils.dart';
import '../media/media_item.dart';
import 'ted_models.dart';
import 'ted_player_loading.dart';

/// Enters the player route immediately. Only a validated session may construct
/// the actual player or emit playback reports.
class TedPreparingPlayer extends StatelessWidget {
  final Future<TedPlaybackSession> session;
  final MediaItem metadata;
  final Widget Function(TedPlaybackSession) player;
  const TedPreparingPlayer({super.key, required this.session, required this.metadata, required this.player});
  @override
  Widget build(BuildContext context) => FutureBuilder<TedPlaybackSession>(
    future: session,
    builder: (context, state) {
      if (state.hasData) return player(state.data!);
      return Focus(
        onKeyEvent: (_, event) => handleBackKeyAction(event, () => Navigator.of(context).pop()),
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                Positioned.fill(
                  child: state.hasError
                      ? Center(
                          child: Text(
                            state.error is TedFailure
                                ? (state.error as TedFailure).message
                                : const TedFailure('unavailable').message,
                          ),
                        )
                      : TedPlayerLoading(media: metadata),
                ),
                Positioned(
                  top: 24,
                  left: 24,
                  child: IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
