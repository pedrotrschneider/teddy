import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_source_lookup.dart';
import 'package:plezy/ted/ted_source_models.dart';

void main() {
  testWidgets('one departing consumer cannot abort a lookup needed by details', (tester) async {
    final response = Completer<TedSourcePage>();
    final leaving = Completer<void>();
    var cancelled = false;
    final lookup = TedSourceLookup((abort) {
      unawaited(abort.then((_) => cancelled = true));
      return response.future;
    });
    final first = lookup.join(leaving.future);
    final failed = expectLater(first, throwsA(isA<TedFailure>()));
    final details = lookup.join(null);
    leaving.complete();
    await tester.pump();
    await failed;
    expect(cancelled, false);
    const page = TedSourcePage(false, false, [], [], null);
    response.complete(page);
    expect(await details, same(page));
    expect(cancelled, false);
  });

  testWidgets('the last departing consumer aborts the shared HTTP request', (tester) async {
    final response = Completer<TedSourcePage>();
    final leaving = Completer<void>();
    var cancelled = false;
    final lookup = TedSourceLookup((abort) {
      unawaited(
        abort.then((_) {
          cancelled = true;
          response.completeError(const TedFailure('unavailable'));
        }),
      );
      return response.future;
    });
    final failed = expectLater(lookup.join(leaving.future), throwsA(isA<TedFailure>()));
    leaving.complete();
    await tester.pump();
    await failed;
    expect(cancelled, true);
    expect(lookup.accepting, false);
    await expectLater(lookup.join(null), throwsA(isA<TedFailure>()));
  });
}
