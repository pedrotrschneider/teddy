import 'dart:async';
import 'package:uuid/uuid.dart';
import 'ted_auth.dart';
import 'ted_models.dart';
import 'ted_source_models.dart';

/// One selected source's speculative work. Playback consumes it; abandoning
/// selection aborts the request and drops any completed server preparation.
class TedPreparation {
  final TedAuth auth;
  final TedMediaIdentity media;
  final String sourceId;
  final bool allowAdd;
  final String operationId = const Uuid().v4();
  final _abort = Completer<void>();
  bool _consumed = false, _cancelled = false;
  bool failed = false;
  int _owners = 0;
  Future<void>? _discarding;
  Future<void> get discarded => _discarding ?? Future<void>.value();
  late Future<void> ready;
  TedPreparation(this.auth, this.media, this.sourceId, {this.allowAdd = false}) {
    _begin();
  }
  Future<void> retry() {
    if (_cancelled || _consumed) return ready;
    if (failed) _begin();
    return ready;
  }

  void invalidate() {
    if (!_cancelled && !_consumed) failed = true;
  }

  void _begin() {
    failed = false;
    ready = auth
        .json(
          'POST',
          '/api/client/v1/playback/preparations',
          body: {
            'media': media.toJson(),
            'source_id': sourceId,
            'operation_id': operationId,
            if (allowAdd) 'allow_add': true,
          },
          abortTrigger: _abort.future,
        )
        .then<void>((value) {
          if (value['ready'] != true) throw const TedFailure('source_preparation_unavailable');
        });
    unawaited(
      ready.then<void>(
        (_) {},
        onError: (Object _) {
          failed = true;
        },
      ),
    );
  }

  bool get reusable => !_cancelled && !failed && !_consumed;
  TedPreparation retain() {
    _owners++;
    return this;
  }

  bool release() {
    if (_owners > 0) _owners--;
    if (_owners > 0) return false;
    discard();
    return true;
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
    } catch (_) {
      _consumed = false;
      rethrow;
    } finally {
      finished = true;
    }
  }

  void discard() {
    if (_consumed || _cancelled) return;
    _cancelled = true;
    _abort.complete();
    _discarding = auth
        .json('DELETE', '/api/client/v1/playback/preparations/$sourceId?operation_id=$operationId')
        .then<void>((_) {})
        .catchError((Object _) {});
    unawaited(_discarding);
  }
}
