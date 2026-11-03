import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_media_transport.dart';
import 'package:plezy/ted/ted_models.dart';

import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_playback_test.dart' show sessionId, mediaPath;

class RelayFixture {
  final payload = List<int>.generate(256 << 10, (index) => index % 251);
  final calls = <(String, String, String)>[];
  final firstPrefix = Completer<void>();
  final retryEntered = Completer<void>();
  Completer<void>? heldBody;
  Completer<void>? heldRetry;
  Completer<void>? heldRefresh;
  final refreshEntered = Completer<void>();
  bool dropFirst = false;
  bool rejectOld = false;
  bool alwaysUnavailable = false;
  String changed = '';
  int rotations = 0;
  DateTime now = DateTime.utc(2026, 11, 2);
  late final HttpServer origin;
  late final TedAuth auth;
  late final TedPlaybackRelay relay;
  final native = HttpClient()..findProxy = (_) => 'DIRECT';
  final errors = <Object>[];
  static Future<RelayFixture> create({
    Duration readTimeout = const Duration(seconds: 8),
    HttpClient? mediaClient,
  }) async {
    final f = RelayFixture();
    f.origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    f.origin.listen((request) => unawaited(f.serve(request).catchError((Object e) => f.errors.add(e))));
    final issued = DateTime.utc(2026, 11, 2);
    f.auth = TedAuth(
      store: MemoryStore(),
      now: () => f.now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/refresh')) {
          f.rotations++;
          if (!f.refreshEntered.isCompleted) f.refreshEntered.complete();
          await f.heldRefresh?.future;
        }
        return response(
          pair(f.now, suffix: f.rotations == 0 ? 'a' : 'b', familyExpiresAt: issued.add(const Duration(days: 90))),
        );
      }),
    );
    await f.auth.login('http://127.0.0.1:${f.origin.port}', 'fixture', '', 'Relay fixture');
    f.relay = TedPlaybackRelay(
      f.auth,
      const TedPlaybackSession(sessionId, TedMediaIdentity('movie', 'tt1234567'), mediaPath, 100000, 0),
      readTimeout: readTimeout,
      client: mediaClient,
    );
    return f;
  }

  Future<void> serve(HttpRequest request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader) ?? '';
    final authorization = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    calls.add((request.method, range, authorization));
    final number = calls.length;
    expect(request.uri.path, mediaPath);
    expect(request.headers.value(HttpHeaders.acceptEncodingHeader), 'identity');
    final out = request.response;
    unawaited(out.done.then((_) {}, onError: (Object _) {}));
    if (alwaysUnavailable || rejectOld && authorization == 'Bearer ted_a_${'a' * 43}') {
      out.statusCode = alwaysUnavailable ? 503 : 401;
      out.contentLength = 0;
      await out.close();
      return;
    }
    if (number > 1) {
      if (!retryEntered.isCompleted) retryEntered.complete();
      await heldRetry?.future;
    }
    var start = 0;
    var end = payload.length - 1;
    if (range.isNotEmpty) {
      final parts = range.substring(6).split('-');
      if (parts[0].isEmpty) {
        start = payload.length - int.parse(parts[1]);
      } else {
        start = int.parse(parts[0]);
        if (parts[1].isNotEmpty) end = int.parse(parts[1]);
      }
    }
    final length = end - start + 1;
    out.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
      ..set(HttpHeaders.etagHeader, number > 1 && changed == 'etag' ? '"different-file"' : '"same-file"')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (number > 1 && changed == 'encoding') out.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
    out.statusCode = range.isEmpty || number > 1 && changed == 'full' ? 200 : 206;
    if (out.statusCode == 206) {
      final reportedStart = number > 1 && changed == 'offset' ? start + 1 : start;
      final reportedSize = number > 1 && changed == 'size' ? payload.length + 1 : payload.length;
      out.headers.set(HttpHeaders.contentRangeHeader, 'bytes $reportedStart-$end/$reportedSize');
    }
    out.contentLength = length;
    if (request.method == 'HEAD') {
      await out.close();
      return;
    }
    if (number == 1 && (dropFirst || heldBody != null)) {
      const prefix = 32 << 10;
      out.add(payload.sublist(start, start + prefix));
      await out.flush();
      firstPrefix.complete();
      await heldBody?.future;
      if (dropFirst) rejectOld = true;
      out.deadline = Duration.zero;
      try {
        await out.close();
      } on HttpException {
        /* intentionally truncated upstream response */
      }
      return;
    }
    out.add(payload.sublist(start, end + 1));
    await out.close();
  }

  Future<HttpClientResponse> get({String range = '', String method = 'GET', String? origin, Uri? target}) async {
    final url = target ?? await relay.open();
    final request = await native.openUrl(method, url);
    if (range.isNotEmpty) request.headers.set(HttpHeaders.rangeHeader, range);
    if (origin != null) request.headers.set('Origin', origin);
    return request.close();
  }

  Future<void> close() async {
    for (final held in [heldBody, heldRetry, heldRefresh]) {
      if (held != null && !held.isCompleted) held.complete();
    }
    await relay.close();
    native.close(force: true);
    await origin.close(force: true);
    auth.close();
  }
}

void main() {
  test('a broken body and 401 continue the same native response at the exact next byte', () async {
    final f = await RelayFixture.create()
      ..dropFirst = true;
    addTearDown(f.close);
    final stream = await f.get(range: 'bytes=4096-200000');
    expect(stream.statusCode, 206);
    final bytes = await stream.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    expect(bytes, f.payload.sublist(4096, 200001));
    expect(f.rotations, 1);
    expect(f.calls.map((call) => call.$2), ['bytes=4096-200000', 'bytes=36864-200000', 'bytes=36864-200000']);
    expect(f.calls.last.$3, 'Bearer ted_a_${'b' * 43}');
    expect(f.errors, isEmpty);
  });

  test('resume reconnects behind retained bytes without closing the native response', () async {
    final f = await RelayFixture.create()
      ..heldBody = Completer<void>()
      ..heldRetry = Completer<void>();
    addTearDown(f.close);
    final stream = await f.get();
    final prefixReceived = Completer<void>();
    final finished = Completer<void>();
    final bytes = <int>[];
    stream.listen(
      (chunk) {
        bytes.addAll(chunk);
        if (bytes.length >= 32 << 10 && !prefixReceived.isCompleted) prefixReceived.complete();
      },
      onDone: finished.complete,
      onError: finished.completeError,
    );
    await prefixReceived.future;
    f.relay.resume();
    await f.retryEntered.future;
    expect(finished.isCompleted, false);
    expect(bytes, f.payload.sublist(0, 32 << 10), reason: 'the native decoder still owns this prefix');
    expect(f.calls.last.$2, 'bytes=32768-262143');
    f.heldRetry!.complete();
    await finished.future;
    expect(bytes, f.payload);
    expect(f.calls, hasLength(2));
    expect(f.rotations, 0);
  });

  test('an idle read reconnects in the producer without requiring native EOF or Play', () async {
    final f = await RelayFixture.create(readTimeout: const Duration(milliseconds: 40))
      ..heldBody = Completer<void>();
    addTearDown(f.close);
    final stream = await f.get();
    final bytes = await stream.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    expect(bytes, f.payload);
    expect(f.calls.map((call) => call.$2), ['', 'bytes=32768-262143']);
    expect(f.rotations, 0);
  });

  test('expired credentials rotate behind retained bytes before the new range is sent', () async {
    final f = await RelayFixture.create()
      ..heldBody = Completer<void>()
      ..heldRefresh = Completer<void>();
    addTearDown(f.close);
    final stream = await f.get();
    final received = <int>[];
    final prefixReceived = Completer<void>();
    var completed = false;
    final body = stream
        .forEach((chunk) {
          received.addAll(chunk);
          if (received.length >= 32 << 10 && !prefixReceived.isCompleted) prefixReceived.complete();
        })
        .whenComplete(() => completed = true);
    await prefixReceived.future;
    f.now = f.now.add(const Duration(minutes: 11));
    f.relay.resume();
    await f.refreshEntered.future;
    expect(completed, false);
    expect(received, f.payload.sublist(0, 32 << 10));
    expect(f.calls, hasLength(1), reason: 'no expired range request reaches TED');
    f.heldRefresh!.complete();
    await body;
    expect(received, f.payload);
    expect(f.calls, hasLength(2));
    expect(f.calls.last.$3, 'Bearer ted_a_${'b' * 43}');
    expect(f.rotations, 1);
  });

  for (final changed in ['etag', 'size', 'offset', 'encoding', 'full']) {
    test('a $changed change cannot append another representation to cached bytes', () async {
      final f = await RelayFixture.create(readTimeout: const Duration(milliseconds: 40))
        ..heldBody = Completer<void>()
        ..changed = changed;
      addTearDown(f.close);
      final stream = await f.get();
      final bytes = <int>[];
      await expectLater(stream.forEach(bytes.addAll), throwsA(isA<HttpException>()));
      expect(bytes, f.payload.sublist(0, 32 << 10));
      expect(f.calls, hasLength(2));
    });
  }

  test('persistent network failure is bounded to three retries', () async {
    final f = await RelayFixture.create()
      ..alwaysUnavailable = true;
    addTearDown(f.close);
    final stream = await f.get();
    expect(stream.statusCode, 503);
    expect(await stream.toList(), isEmpty);
    expect(f.calls, hasLength(4));
    expect(f.rotations, 0);
  });

  test('stop during credential rotation fences the late response and closes the local stream', () async {
    final f = await RelayFixture.create()
      ..rejectOld = true
      ..heldRefresh = Completer<void>();
    addTearDown(f.close);
    final result = f.get().then<void>((response) => response.drain<void>());
    final failure = expectLater(result, throwsA(isA<HttpException>()));
    await f.refreshEntered.future;
    await f.relay.close();
    f.heldRefresh!.complete();
    await failure;
    await f.auth.headers();
    expect(f.calls, hasLength(1));
    expect(f.rotations, 1);
  });

  test('HEAD and suffix/finite ranges retain the pinned size and exact bytes', () async {
    final f = await RelayFixture.create();
    addTearDown(f.close);
    final head = await f.get(method: 'HEAD');
    expect(head.statusCode, 200);
    expect(head.contentLength, f.payload.length);
    expect(await head.toList(), isEmpty);
    for (final range in ['bytes=-1024', 'bytes=23-4095']) {
      final stream = await f.get(range: range);
      final bytes = await stream.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      expect(
        bytes,
        range.startsWith('bytes=-') ? f.payload.sublist(f.payload.length - 1024) : f.payload.sublist(23, 4096),
      );
    }
    final url = await f.relay.open();
    expect(url.host, '127.0.0.1');
    expect(url.query, isEmpty);
  });

  test('unrecognized local requests cannot reach TED or obtain credentials', () async {
    final f = await RelayFixture.create();
    addTearDown(f.close);
    final url = await f.relay.open();
    for (final operation in [
      () => f.get(target: url.replace(path: '/another-session')),
      () => f.get(origin: 'https://unrelated.example'),
      () => f.get(method: 'DELETE'),
      () => f.get(range: 'bytes=0-1,5-6'),
    ]) {
      final result = await operation();
      expect(result.statusCode, anyOf(404, 405, 416));
      await result.drain<void>();
    }
    expect(f.calls, isEmpty);
  });

  test('stop while opening the loopback listener retires a late bind without admitting a stream', () async {
    final f = await RelayFixture.create();
    addTearDown(f.close);
    final opening = f.relay.open();
    final failure = expectLater(
      opening,
      throwsA(isA<TedFailure>().having((error) => error.code, 'code', 'sign_in_required')),
    );
    await f.relay.close();
    await failure;
    expect(f.calls, isEmpty);
  });

  test('stop during connection admission closes a late socket without sending a media request', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final client = HttpClient();
    client.connectionFactory = (url, proxyHost, proxyPort) async {
      final socket = await Socket.connect(url.host, url.port);
      entered.complete();
      await release.future;
      return ConnectionTask.fromSocket(Future.value(socket), socket.destroy);
    };
    final f = await RelayFixture.create(mediaClient: client);
    addTearDown(f.close);
    final failure = expectLater(f.get(), throwsA(anyOf(isA<HttpException>(), isA<SocketException>())));
    await entered.future;
    await f.relay.close();
    release.complete();
    await failure;
    expect(f.calls, isEmpty);
  });
}
