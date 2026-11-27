import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_next_cache.dart';
import 'package:plezy/ted/ted_startup_trace.dart';
import 'ted_media_transport_test.dart' show RelayFixture;
import 'ted_playback_test.dart' show sessionId;

class DirectHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'fragmented cached bytes preserve later continuation headers, first-byte and summary trace',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final logs = <String>[];
      final summary = Completer<void>();
      const identity = TedMediaIdentity('movie', 'tt1234567');
      final cache = TedNextByteCache(
        identity,
        const TedCachePlan(
          size: 256 << 10,
          etag: '"same-file"',
          resumeMs: 0,
          durationMs: 100000,
          start: 0,
          end: (128 << 10) - 1,
          aheadBytes: 256 << 10,
          backBytes: 0,
        ),
      );
      addTearDown(cache.dispose);
      final f = await RelayFixture.create(
        cache: cache,
        traceStartup: true,
        traceLog: (line) {
          logs.add(line);
          if (line.contains('phase=request_finished ') && !summary.isCompleted) summary.complete();
        },
      );
      addTearDown(f.close);
      for (var offset = 0; offset < 128 << 10; offset += 128) {
        cache.put(offset, f.payload.sublist(offset, offset + 1));
        cache.put(offset + 1, f.payload.sublist(offset + 1, offset + 128));
      }
      final out = await f.get();
      expect(await out.fold<List<int>>([], (all, b) => all..addAll(b)), f.payload);
      await summary.future;
      expect(f.calls.map((v) => (v.$1, v.$2)), [('HEAD', ''), ('GET', 'bytes=131072-262143')]);
      expect(logs.any((v) => v.contains('phase=upstream_headers_ready ') && v.contains('upstream=2')), true);
      expect(logs.any((v) => v.contains('phase=body_wait_done ') && v.contains('first=1')), true);
      expect(logs.last, contains('cached_bytes=131072 cached_writes=2048 network_bytes=131072'));
      expect(logs.any((v) => v.contains('phase=trace_limit ')), false);
      expect(logs.length, lessThan(150));
    }, DirectHttp()),
  );

  test('chunk sample floods reserve capacity for headers, first bytes and terminal phases', () {
    final logs = <String>[];
    final trace = TedStartupTrace(sessionId, enabled: true, log: logs.add);
    for (var i = 0; i < 10000; i++) {
      trace.event('write_flushed');
    }
    trace.event('upstream_headers_ready', values: {'status': 206});
    trace.event('body_wait_done', values: {'first': 1, 'bytes': 1024});
    trace.event('request_finished');
    expect(trace.active, true);
    expect(logs.where((v) => v.contains('phase=trace_samples_limited ')).length, 1);
    expect(logs.skip(logs.length - 3).map((v) => RegExp(r'phase=(\w+)').firstMatch(v)![1]), [
      'upstream_headers_ready',
      'body_wait_done',
      'request_finished',
    ]);
  });
  test(
    'cold trace separates held upstream headers from first media bytes without changing delivery',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final logs = <String>[];
      final progress = Completer<void>();
      final f = await RelayFixture.create(
        traceStartup: true,
        traceLog: (line) {
          logs.add(line);
          if (line.contains('phase=transport_progress ') && !progress.isCompleted) progress.complete();
        },
      );
      addTearDown(f.close);
      f.heldHeaders = Completer<void>();
      final getting = f.get();
      await f.headersEntered.future;
      expect(logs.any((v) => v.contains('phase=upstream_headers_begin ')), true);
      expect(logs.any((v) => v.contains('phase=upstream_headers_ready ')), false);
      expect(logs.any((v) => v.contains('phase=write_begin ')), false);
      await progress.future.timeout(const Duration(seconds: 7));
      final blocked = logs.firstWhere((line) => line.contains('phase=transport_progress '));
      expect(blocked, contains('wait_stage=3'));
      expect(blocked, contains('received_bytes=0'));
      final sentId = f.diagnosticCalls.single.$1;
      expect(tedUuid(sentId ?? ''), true);
      expect(f.diagnosticCalls.single.$2, '1');
      expect(blocked, contains('client_request_id=$sentId'));
      f.heldHeaders!.complete();
      final out = await getting;
      expect(await out.fold<List<int>>([], (all, b) => all..addAll(b)), f.payload);
      final headers = logs.indexWhere((v) => v.contains('phase=upstream_headers_ready '));
      final first = logs.indexWhere((v) => v.contains('phase=body_wait_done ') && v.contains('first=1'));
      final write = logs.indexWhere((v) => v.contains('phase=write_begin '));
      expect(first, greaterThan(headers));
      expect(write, greaterThan(first));
      expect(logs.any((v) => v.contains('phase=write_flushed ') && v.contains('cached=0')), true);
      expect(logs[headers], contains('server_request_id=00000000-0000-4000-8000-000000000001'));
      expect(logs.join(), isNot(contains('Authorization')));
      expect(logs.join(), isNot(contains('http://')));
      expect(logs.join(), isNot(contains('Bearer')));
      expect(f.errors, isEmpty);
    }, DirectHttp()),
  );

  test(
    'cached trace records hit before held fresh validation and cached flush after it',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final logs = <String>[];
      const identity = TedMediaIdentity('movie', 'tt1234567');
      final cache = TedNextByteCache(
        identity,
        const TedCachePlan(
          size: 256 << 10,
          etag: '"same-file"',
          resumeMs: 0,
          durationMs: 100000,
          start: 0,
          end: 4095,
          aheadBytes: 8192,
          backBytes: 0,
        ),
      );
      addTearDown(cache.dispose);
      final f = await RelayFixture.create(cache: cache, traceStartup: true, traceLog: logs.add);
      addTearDown(f.close);
      cache.put(0, f.payload.sublist(0, 4096));
      f.heldHeaders = Completer<void>();
      final getting = f.get(range: 'bytes=0-4095');
      await f.headersEntered.future;
      expect(logs.any((v) => v.contains('phase=cache_hit ')), true);
      expect(logs.any((v) => v.contains('phase=cache_verified ')), false);
      expect(logs.any((v) => v.contains('phase=write_begin ')), false);
      f.heldHeaders!.complete();
      final out = await getting;
      expect(await out.fold<List<int>>([], (all, b) => all..addAll(b)), f.payload.sublist(0, 4096));
      expect(f.calls.map((v) => v.$1), ['HEAD']);
      final verified = logs.indexWhere((v) => v.contains('phase=cache_verified '));
      final write = logs.indexWhere((v) => v.contains('phase=write_begin ') && v.contains('cached=1'));
      final flushed = logs.indexWhere((v) => v.contains('phase=write_flushed ') && v.contains('cached=1'));
      expect(write, greaterThan(verified));
      expect(flushed, greaterThan(write));
    }, DirectHttp()),
  );

  test('diagnostic bounds and failing log sinks cannot affect media operations', () {
    final logs = <String>[];
    final trace = TedStartupTrace(sessionId, enabled: true, log: logs.add);
    trace.event('https://private.invalid/token');
    trace.event('valid', values: {'secret header': 1});
    trace.event('valid', values: {'bytes': 9007199254740992});
    expect(logs, isEmpty);
    for (var i = 0; i < TedStartupTrace.eventLimit + 100; i++) {
      trace.event('sample');
    }
    expect(logs.length, TedStartupTrace.eventLimit + 1);
    expect(logs.last, contains('phase=trace_limit '));
    expect(trace.active, false);
    final broken = TedStartupTrace(sessionId, enabled: true, log: (_) => throw StateError('sink'));
    expect(() => broken.event('sample'), returnsNormally);
    TedStartupTrace(sessionId, enabled: false, log: logs.add).event('disabled');
    expect(logs.length, TedStartupTrace.eventLimit + 1);
  });

  test('late transport phases, blocked-call progress and terminal records survive both startup limits', () {
    var elapsed = Duration.zero;
    final logs = <String>[];
    final trace = TedStartupTrace(sessionId, enabled: true, log: logs.add, elapsedOverride: () => elapsed);
    for (var i = 0; i < 10000; i++) {
      trace.event('write_flushed', transport: true);
    }
    for (var i = 0; i < 10000; i++) {
      trace.event('upstream_headers_ready', transport: true);
    }
    expect(logs.length, lessThan(800));
    for (var i = 0; i < 1100; i++) {
      trace.event('milestone');
    }
    expect(trace.active, false);
    elapsed = const Duration(minutes: 20);
    expect(trace.active, false);
    trace.event('upstream_headers_ready', transport: true, clientRequestId: sessionId, values: {'upstream': 24});
    for (var i = 0; i < 10000; i++) {
      trace.event('upstream_open_begin', transport: true);
    }
    trace.event('transport_progress', transport: true, values: {'wait_stage': 5, 'wait_us': 8000000});
    trace.event('request_finished', transport: true, terminal: true, values: {'received_bytes': 1234567});
    expect(logs.any((v) => v.contains('client_request_id=$sessionId') && v.contains('upstream=24')), true);
    expect(logs[logs.length - 2], contains('wait_stage=5 wait_us=8000000'));
    expect(logs.last, contains('received_bytes=1234567'));
    expect(logs.length, lessThan(1600));
    trace.event('request_finished', transport: true, terminal: true, serverRequestId: 'https://private.invalid/SECRET');
    expect(logs.join(), isNot(contains('SECRET')));
  });

  test(
    'authentication retries have distinct request IDs and optional malformed trace headers cannot break media',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final logs = <String>[];
      final summary = Completer<void>();
      final f = await RelayFixture.create(
        traceStartup: true,
        traceLog: (line) {
          logs.add(line);
          if (line.contains('phase=request_finished ') && !summary.isCompleted) summary.complete();
        },
      );
      addTearDown(f.close);
      f.rejectOld = true;
      f.invalidTraceHeader = true;
      final out = await f.get();
      expect(await out.fold<List<int>>([], (all, b) => all..addAll(b)), f.payload);
      await summary.future;
      expect(f.diagnosticCalls.length, 2);
      final ids = f.diagnosticCalls.map((v) => v.$1).toSet();
      expect(ids.length, 2);
      expect(ids.every((v) => tedUuid(v ?? '')), true);
      final headers = logs.where((v) => v.contains('phase=upstream_headers_ready ')).toList();
      expect(headers.length, 2);
      expect(headers[0], contains('upstream=1'));
      expect(headers[1], contains('upstream=2'));
      expect(logs.last, contains('complete=1'));
      expect(logs.last, contains('received_bytes=${f.payload.length}'));
      expect(logs.last, contains('network_bytes=${f.payload.length}'));
      expect(logs.join(), isNot(contains('SECRET')));
      expect(f.errors, isEmpty);
    }, DirectHttp()),
  );
}
