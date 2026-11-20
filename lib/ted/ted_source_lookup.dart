import 'dart:async';
import 'ted_models.dart';
import 'ted_source_models.dart';

/// Coalesces a lookup without letting one cancelled consumer abort another.
/// The HTTP request is cancelled when every live consumer has left.
class TedSourceLookup {
  final _abort = Completer<void>();
  late final Future<TedSourcePage> result;
  int _owners = 0;
  bool finished = false, accepting = true;
  TedSourceLookup(Future<TedSourcePage> Function(Future<void>) load) {
    result = Future.sync(() => load(_abort.future));
    unawaited(
      result.then<void>(
        (_) {
          finished = true;
        },
        onError: (Object _) {
          finished = true;
        },
      ),
    );
  }
  Future<TedSourcePage> join(Future<void>? abort) async {
    if (!accepting) throw const TedFailure('unavailable');
    _owners++;
    var done = false;
    final cancelled = abort?.then<TedSourcePage>((_) {
      if (done) return result;
      throw const TedFailure('unavailable');
    });
    try {
      return await (cancelled == null ? result : Future.any([result, cancelled]));
    } finally {
      done = true;
      _owners--;
      if (_owners == 0 && !finished) {
        accepting = false;
        if (!_abort.isCompleted) _abort.complete();
      }
    }
  }
}
