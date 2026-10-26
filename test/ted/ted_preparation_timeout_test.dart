import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair;

class HeldPreparationClient extends http.BaseClient {
  final DateTime now;
  final calls = <String, Completer<http.StreamedResponse>>{};
  final aborted = <String>[];
  HeldPreparationClient(this.now);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.endsWith('/login')) return Future.value(reply(pair(now)));
    final path = request.url.path;
    final pending = Completer<http.StreamedResponse>();
    calls[path] = pending;
    (request as http.AbortableRequest).abortTrigger!.then((_) {
      if (pending.isCompleted) return;
      aborted.add(path);
      pending.completeError(http.RequestAbortedException(request.url));
    });
    return pending.future;
  }

  http.StreamedResponse reply(Map<String, dynamic> value, [int status = 200]) => http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(value))),
    status,
    headers: {'x-ted-compatibility-version': '0.3'},
  );
}

void main() {
  testWidgets('selected file preparation outlives discovery while ordinary requests remain bounded', (tester) async {
    final now = DateTime.utc(2026, 10, 13);
    final client = HeldPreparationClient(now);
    final auth = TedAuth(store: MemoryStore(), client: client, now: () => now);
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    const preparationPath = '/api/client/v1/playback/sessions';
    const discoveryPath = '/api/client/v1/catalog/movie';
    final preparation = auth.json('POST', preparationPath);
    final discovery = auth.json('GET', discoveryPath);
    final failedDiscovery = expectLater(
      discovery,
      throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'unavailable')),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await failedDiscovery;
    expect(client.aborted, [discoveryPath]);
    expect(client.calls[preparationPath]!.isCompleted, false);
    client.calls[preparationPath]!.complete(client.reply({'ready': true}, 201));
    await tester.pump();
    expect(await preparation, {'ready': true});
    expect(auth.signedIn, true);
  });

  testWidgets('source lookups outlive ordinary JSON requests but remain bounded', (tester) async {
    final now = DateTime.utc(2026, 10, 13);
    final client = HeldPreparationClient(now);
    final auth = TedAuth(store: MemoryStore(), client: client, now: () => now);
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    const path = '/api/client/v1/playback/sources';
    final lookup = auth.json('POST', path);
    await tester.pump();
    await tester.pump(const Duration(seconds: 13));
    expect(client.aborted, isEmpty);
    client.calls[path]!.complete(client.reply({'sources': []}));
    await tester.pump();
    expect(await lookup, {'sources': []});
    final hung = auth.json('POST', path);
    final timeout = expectLater(hung, throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'unavailable')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await timeout;
    expect(client.aborted, [path]);
    expect(auth.signedIn, true);
  });

  testWidgets('preparation remains bounded and preserves server preparation failures', (tester) async {
    final now = DateTime.utc(2026, 10, 13);
    final client = HeldPreparationClient(now);
    final auth = TedAuth(store: MemoryStore(), client: client, now: () => now);
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    const path = '/api/client/v1/playback/sessions';
    final preparation = auth.json('POST', path);
    final timeout = expectLater(preparation, throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'unavailable')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 51));
    await timeout;
    expect(client.aborted, [path]);
    final rejected = auth.json('POST', path);
    final failure = expectLater(
      rejected,
      throwsA(isA<TedFailure>().having((e) => e.code, 'code', 'source_preparation_unavailable')),
    );
    await tester.pump();
    client.calls[path]!.complete(client.reply({'code': 'source_preparation_unavailable'}, 503));
    await tester.pump();
    await failure;
    expect(auth.signedIn, true);
  });
}
