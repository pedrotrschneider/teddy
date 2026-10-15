import 'dart:async';
import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_preparation.dart';
import 'ted_season_source.dart';

/// A single next-episode lookup per playing session, never a general queue.
class TedNextPreparation {
  final TedClient client;
  final TedTitle target;
  final _abort = Completer<void>();
  bool _discarded = false;
  TedPreparation? _preparation;
  late final Future<String?> source;
  TedNextPreparation(this.client, this.target, TedPlaybackSession session) {
    source = _load(session).catchError((Object _) => null);
  }
  Future<String?> _load(TedPlaybackSession session) async {
    final page = await client.stremioSources(
      target.media,
      preferredAddonId: session.addonId,
      abortTrigger: _abort.future,
    );
    if (_discarded) return null;
    final id = TedSeasonSource.fromSession(session).match(page);
    final choice = page.choices.where((c) => c.id == id).firstOrNull;
    if (choice == null || !TedPreparation.eligible(choice)) return null;
    client.stagePreparedSources(target.media, page);
    _preparation = client.prepareSource(target.media, choice.id);
    await _preparation!.ready;
    return _discarded ? null : choice.id;
  }

  void discard() {
    _discarded = true;
    client.takePreparedSources(target.media);
    if (!_abort.isCompleted) _abort.complete();
    client.discardPreparation(_preparation);
  }
}
