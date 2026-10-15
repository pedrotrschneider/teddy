import 'dart:async';
import 'ted_auth.dart';
import 'ted_models.dart';
import 'ted_source_models.dart';

/// One selected source's speculative work. Playback consumes it; abandoning
/// selection aborts the request and drops any completed server preparation.
class TedPreparation {
  final TedAuth auth;
  final TedMediaIdentity media;
  final String sourceId;
  final _abort = Completer<void>();
  bool _consumed = false, _cancelled = false;
  late final Future<void> ready;
  TedPreparation(this.auth, this.media, this.sourceId) {
    ready = auth
        .json(
          'POST',
          '/api/client/v1/playback/preparations',
          body: {'media': media.toJson(), 'source_id': sourceId},
          abortTrigger: _abort.future,
        )
        .then<void>((_) {})
        .catchError((Object _) {});
  }
  static bool eligible(TedSourceChoice choice) => choice.rdDirectPlay && choice.inRDAccount;
  Future<void> consume({Future<void>? abortTrigger}) async {
    _consumed = true;
    var finished = false;
    final cancelled = abortTrigger?.then<void>((_) {
      if (finished) return;
      _consumed = false;
      discard();
      throw const TedFailure('unavailable');
    });
    try {
      await (cancelled == null ? ready : Future.any([ready, cancelled]));
    } finally {
      finished = true;
    }
  }

  void discard() {
    if (_consumed || _cancelled) return;
    _cancelled = true;
    _abort.complete();
    unawaited(
      auth
          .json('DELETE', '/api/client/v1/playback/preparations/$sourceId')
          .catchError((Object _) => <String, dynamic>{}),
    );
  }
}
