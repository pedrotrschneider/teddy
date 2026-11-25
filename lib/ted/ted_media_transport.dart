import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../utils/app_logger.dart';
import 'ted_auth.dart';
import 'ted_models.dart';
import 'ted_next_cache.dart';
import 'ted_startup_trace.dart';

/// The decoder keeps its own packet cache. Only the byte transport reconnects.
abstract interface class TedMediaTransport {
  Future<Uri> open();
  void resume();
  Future<void> close();
}

/// A single-session loopback stream, with an optional bounded encoded-byte
/// cache adopted from next-episode preparation. It never writes a disk cache.
/// MPV's demuxer reads it independently of the paused video decoder.
/// Interrupted TED reads resume at the next byte, leaving decoded/cached packets
/// and the native HTTP response intact. Every upstream request uses TedAuth.
class TedPlaybackRelay implements TedMediaTransport {
  final TedAuth _auth;
  final TedPlaybackSession _session;
  final Uri _server;
  final int? _user;
  final String? _family;
  final HttpClient _client;
  final Duration _headerTimeout;
  final Duration readTimeout;
  final TedNextByteCache? cache;
  final _path = '/${const Uuid().v4()}/media';
  final _active = <_RelayRead>{};
  final _cancelled = Completer<void>();
  HttpServer? _listener;
  Future<Uri>? _opening;
  Future<void>? _closing;
  bool _closed = false;
  int? _size;
  String? _etag;
  late final TedStartupTrace _trace;
  int _requestSequence = 0;

  TedPlaybackRelay(
    TedAuth auth,
    TedPlaybackSession session, {
    HttpClient? client,
    Duration headerTimeout = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 8),
    this.cache,
    bool traceStartup = tedStartupTraceEnabled,
    void Function(String)? traceLog,
  }) : _auth = auth,
       _session = session,
       _server = auth.server!,
       _user = auth.userId,
       _family = auth.familyId,
       _client = client ?? HttpClient(),
       _headerTimeout = headerTimeout {
    final path = '/api/client/v1/playback/sessions/${session.id}/media';
    if (!tedUuid(session.id) || session.mediaPath != path) throw const TedFailure('invalid_response');
    _trace = TedStartupTrace(session.id, enabled: traceStartup, log: traceLog);
    _client
      ..autoUncompress = false
      ..connectionTimeout = headerTimeout
      ..findProxy = (_) => 'DIRECT';
    if (cache != null && !cache!.disposed) {
      _size = cache!.plan.size;
      _etag = cache!.plan.etag;
      final plan = cache!.plan;
      _trace.event(
        'cache_plan',
        values: {
          'size': plan.size,
          'resume_ms': plan.resumeMs,
          'playable_start': plan.start,
          'playable_end': plan.end,
          'ahead_bytes': plan.aheadBytes,
          'back_bytes': plan.backBytes,
        },
      );
      for (final span in plan.ranges) {
        _trace.event('cache_plan_range', values: {'start': span.$1, 'end': span.$2});
      }
    }
  }

  bool get _current =>
      !_closed && _auth.signedIn && _auth.server == _server && _auth.userId == _user && _auth.familyId == _family;

  void _checkCurrent() {
    if (!_current) throw const TedFailure('sign_in_required');
  }

  @override
  Future<Uri> open() => _opening ??= _open();

  Future<Uri> _open() async {
    _trace.event('listener_begin');
    _checkCurrent();
    final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (!_current) {
      await listener.close(force: true);
      throw const TedFailure('sign_in_required');
    }
    _listener = listener;
    _trace.event('listener_ready', values: {'cached_bytes': cache?.bytes ?? 0});
    listener.listen((request) => unawaited(_serve(request)), onError: (Object _) {});
    return Uri(scheme: 'http', host: '127.0.0.1', port: listener.port, path: _path);
  }

  @override
  void resume() {
    // Unpause does not await this work. A read already blocked by a full native
    // cache resumes at its byte offset as soon as the demuxer has room again.
    if (!_current) return;
    for (final read in _active) {
      read.restart = true;
      unawaited(read.interrupt());
    }
  }

  void _log(String phase, int offset, int attempt, String code) => appLogger.i(
    'TED media transport: phase=$phase session=${_session.id} offset_bytes=$offset attempt=$attempt code=$code',
  );

  Future<HttpClientResponse> _connect(_RelayRead read, String method, String range) async {
    for (var authentication = 0; ; authentication++) {
      read.upstream++;
      _io(read, 'auth_begin', {'upstream': read.upstream});
      _checkCurrent();
      final headers = await _auth.headers();
      _io(read, 'auth_ready', {'upstream': read.upstream});
      _checkCurrent();
      if (read.cancelled) throw const _RelayClosed();
      final generation = read.generation;
      _io(read, 'upstream_open_begin', {
        'upstream': read.upstream,
        'head': method == 'HEAD' ? 1 : 0,
        ..._rangeNumbers(range),
      });
      final request = await _client
          .openUrl(method, _server.resolve(_session.mediaPath))
          .then((request) {
            // A stop/timeout may retire this request before close() has
            // attached its own response listener. Consume abort's future too.
            unawaited(request.done.then((_) {}, onError: (Object _) {}));
            if (!_current || read.cancelled || read.generation != generation) {
              request.abort();
              throw const _RelayClosed();
            }
            return request;
          })
          .timeout(_headerTimeout);
      _io(read, 'upstream_open_ready', {'upstream': read.upstream});
      read.request = request;
      if (!_current || read.cancelled) {
        request.abort();
        throw const _RelayClosed();
      }
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range.isNotEmpty) request.headers.set(HttpHeaders.rangeHeader, range);
      if (_etag != null && range.isNotEmpty) request.headers.set(HttpHeaders.ifRangeHeader, _etag!);
      _io(read, 'upstream_headers_begin', {'upstream': read.upstream});
      final response = await request.close().timeout(
        _headerTimeout,
        onTimeout: () {
          request.abort();
          throw TimeoutException('media headers');
        },
      );
      _io(read, 'upstream_headers_ready', {
        'upstream': read.upstream,
        'status': response.statusCode,
        'length': response.contentLength,
      });
      _checkCurrent();
      if (read.cancelled) {
        await response.listen(null).cancel();
        throw const _RelayClosed();
      }
      if (response.statusCode != 401 || authentication > 0) return response;
      await response.listen(null).cancel();
      final current = await _auth.headers();
      _checkCurrent();
      if (current['Authorization'] == headers['Authorization']) {
        await _auth.refresh();
      }
      _checkCurrent();
      _log('authenticate', read.offset, authentication + 1, 'http_401');
    }
  }

  _RelayRange _validate(HttpClientResponse response, String requested) {
    final status = response.statusCode;
    if (status != 200 && status != 206) {
      throw _RelayStatus(status, retryAfter: tedRetryAfter(response.headers.value(HttpHeaders.retryAfterHeader)));
    }
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding != 'identity') throw const TedFailure('invalid_response');
    final length = response.contentLength;
    if (length <= 0) throw const TedFailure('invalid_response');
    final _RelayRange span;
    if (status == 206) {
      final match = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      if (match == null) throw const TedFailure('invalid_response');
      span = _RelayRange(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
    } else {
      span = _RelayRange(0, length - 1, length);
    }
    final expected = _RelayRange.request(requested, span.size);
    if (span.size <= 0 ||
        span.end >= span.size ||
        span.start != expected.start ||
        span.end != expected.end ||
        length != span.end - span.start + 1 ||
        requested.isNotEmpty && status != 206) {
      throw const TedFailure('invalid_response');
    }
    final etag = response.headers.value(HttpHeaders.etagHeader);
    if (_size != null && (_size != span.size || _etag != etag)) {
      throw const TedFailure('source_selection_required');
    }
    _size = span.size;
    _etag = etag;
    return span;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final read = _RelayRead(++_requestSequence);
    var sentHeaders = false;
    _active.add(read);
    unawaited(response.done.then((_) => read.cancel(), onError: (Object _) => read.cancel()));
    try {
      if (request.uri.path != _path ||
          request.uri.hasQuery ||
          request.headers.value('Origin') != null ||
          request.connectionInfo?.remoteAddress.isLoopback != true) {
        throw const _RelayStatus(404);
      }
      if (request.method != 'GET' && request.method != 'HEAD') throw const _RelayStatus(405);
      _checkCurrent();
      final originalRange = request.method == 'HEAD' ? '' : request.headers.value(HttpHeaders.rangeHeader) ?? '';
      if (!_RelayRange.validRequest(originalRange)) throw const _RelayStatus(416);
      _io(read, 'request_received', {'head': request.method == 'HEAD' ? 1 : 0, ..._rangeNumbers(originalRange)});
      var range = originalRange;
      int? end;
      var retries = 0;
      final retained = cache;
      if (request.method == 'GET' && retained != null && !retained.disposed) {
        final wanted = _RelayRange.request(originalRange, retained.plan.size);
        _io(read, 'cache_lookup', {'start': wanted.start, 'end': wanted.end});
        final initialCache = retained.read(wanted.start, wanted.end);
        if (initialCache != null) {
          _io(read, 'cache_hit', {'start': wanted.start, 'end': wanted.end, 'available_bytes': initialCache.length});
          // Cached bytes never replace current authorization/file checks.
          // HEAD is cheap on the warmed server and uses fresh TED credentials.
          final authorized = await _connect(read, 'HEAD', '');
          final verified = _validate(authorized, '');
          await authorized.listen(null).cancel();
          if (verified.size != retained.plan.size) throw const TedFailure('source_selection_required');
          _io(read, 'cache_verified', {'size': verified.size});
          end = wanted.end;
          read.offset = wanted.start;
          response.statusCode = originalRange.isEmpty ? 200 : 206;
          response.contentLength = end - read.offset + 1;
          response.headers
            ..set(
              HttpHeaders.contentTypeHeader,
              authorized.headers.value(HttpHeaders.contentTypeHeader) ?? 'application/octet-stream',
            )
            ..set(HttpHeaders.etagHeader, retained.plan.etag)
            ..set(HttpHeaders.acceptRangesHeader, 'bytes')
            ..set(HttpHeaders.cacheControlHeader, 'private, no-store');
          if (originalRange.isNotEmpty) {
            response.headers.set(HttpHeaders.contentRangeHeader, 'bytes ${read.offset}-$end/${verified.size}');
          }
          sentHeaders = true;
          var bytes = retained.read(read.offset, end);
          while (bytes != null) {
            _checkCurrent();
            if (read.cancelled) throw const _RelayClosed();
            await _write(read, response, bytes, cached: true);
            read.offset += bytes.length;
            if (read.offset > end) {
              _log('cache_reused', read.offset, 0, 'none');
              await response.close();
              return;
            }
            bytes = retained.read(read.offset, end);
          }
          _log('cache_reused', read.offset, 0, 'none');
          _io(read, 'cache_continuation', {'offset': read.offset});
          range = 'bytes=${read.offset}-$end';
        } else {
          _io(read, 'cache_miss', {'start': wanted.start, 'end': wanted.end});
        }
      } else {
        _io(read, 'cache_absent');
      }
      while (!read.cancelled && _current) {
        try {
          read.restart = false;
          final upstream = await _connect(read, request.method, range);
          final body = StreamIterator(upstream);
          read.body = body;
          read.packets = 0;
          final span = _validate(upstream, range);
          if (sentHeaders && (span.start != read.offset || span.end != end)) {
            throw const TedFailure('invalid_response');
          }
          if (!sentHeaders) {
            end = span.end;
            read.offset = span.start;
            response
              ..statusCode = upstream.statusCode
              ..contentLength = upstream.contentLength;
            for (final name in [
              HttpHeaders.contentTypeHeader,
              HttpHeaders.contentRangeHeader,
              HttpHeaders.etagHeader,
            ]) {
              final value = upstream.headers.value(name);
              if (value != null) response.headers.set(name, value);
            }
            response.headers
              ..set(HttpHeaders.acceptRangesHeader, 'bytes')
              ..set(HttpHeaders.cacheControlHeader, 'private, no-store');
            sentHeaders = true;
          }
          if (request.method == 'HEAD') {
            await body.cancel();
            await response.close();
            return;
          }
          var reusedCache = false;
          while (await _readBody(read, body)) {
            _checkCurrent();
            if (read.cancelled) throw const _RelayClosed();
            final bytes = body.current;
            if (bytes.length > end! - read.offset + 1) throw const TedFailure('invalid_response');
            await _write(read, response, bytes, cached: false);
            read.offset += bytes.length;
            if (read.offset > end) break;
            var retained = cache?.read(read.offset, end);
            if (retained != null) {
              _io(read, 'cache_hit_after_upstream', {'offset': read.offset, 'bytes': retained.length});
              await body.cancel();
              read.body = null;
              reusedCache = true;
              while (retained != null) {
                _checkCurrent();
                if (read.cancelled) throw const _RelayClosed();
                await _write(read, response, retained, cached: true);
                read.offset += retained.length;
                if (read.offset > end) break;
                retained = cache?.read(read.offset, end);
              }
              _log('cache_reused', read.offset, 0, 'none');
              break;
            }
            if (read.restart) break;
          }
          await body.cancel();
          read.body = null;
          if (read.offset > end!) {
            await response.close();
            return;
          }
          if (reusedCache) {
            range = 'bytes=${read.offset}-$end';
            continue;
          }
          throw const HttpException('interrupted media body');
        } catch (error) {
          await read.interrupt();
          if (read.cancelled || !_current) rethrow;
          if (error is TedFailure || error is _RelayStatus && !error.retryable) rethrow;
          if (!read.restart && retries++ >= 3) rethrow;
          final reason = read.restart
              ? 'resume'
              : error is _RelayStatus
              ? 'http_${error.status}'
              : 'read_interrupted';
          _log('reconnect', read.offset, retries, reason);
          if (sentHeaders) range = 'bytes=${read.offset}-$end';
          if (!read.restart) {
            await Future.any([Future<void>.delayed(Duration(milliseconds: 250 * retries)), _cancelled.future]);
          }
        }
      }
      throw const _RelayClosed();
    } catch (error) {
      if (!read.cancelled && !_closed) {
        _log(
          'failed',
          read.offset,
          0,
          error is TedFailure
              ? error.code
              : error is _RelayStatus
              ? 'http_${error.status}'
              : 'unavailable',
        );
      }
      if (!sentHeaders) {
        response.statusCode = error is _RelayStatus
            ? error.status
            : error is TedFailure && error.code == 'sign_in_required'
            ? 401
            : 502;
        response.contentLength = 0;
        try {
          await response.close();
        } catch (_) {
          /* disconnected native reader */
        }
      } else {
        // HttpResponse.detachSocket is only legal before headers are sent.
        // A terminal short body must close this connection without fabricating
        // bytes or leaving the native reader waiting for its Content-Length.
        response.deadline = Duration.zero;
        try {
          await response.close();
        } catch (_) {
          /* already disconnected */
        }
      }
    } finally {
      _io(read, 'request_finished', {
        'offset': read.offset,
        'cancelled': read.cancelled ? 1 : 0,
        'cached_bytes': read.cachedBytes,
        'cached_writes': read.cachedWrites,
        'network_bytes': read.networkBytes,
        'network_writes': read.networkWrites,
        'max_flush_us': read.maxFlushUs,
        'max_body_wait_us': read.maxBodyWaitUs,
      });
      await read.cancel();
      _active.remove(read);
    }
  }

  /// Fill the bounded forward window before the backward window. A failed
  /// attempt preserves already validated chunks for the minute retry.
  Future<void> preCache() async {
    final retained = cache;
    if (retained == null || retained.disposed || retained.suspended) throw const TedFailure('next_cache_evicted');
    for (final span in retained.plan.ranges) {
      await _cacheRange(retained, span.$1, span.$2);
    }
    _checkCurrent();
    retained.ready = true;
    _log('cache_ready', retained.bytes, 0, 'none');
  }

  Future<void> _cacheRange(TedNextByteCache retained, int start, int end) async {
    final read = _RelayRead(++_requestSequence);
    _active.add(read);
    _io(read, 'cache_fill_begin', {'start': start, 'end': end});
    try {
      while (start <= end) {
        _checkCurrent();
        if (retained.disposed || retained.suspended) throw const TedFailure('next_cache_evicted');
        final held = retained.read(start, end);
        if (held != null) {
          start += held.length;
          continue;
        }
        final range = 'bytes=$start-$end';
        final upstream = await _connect(read, 'GET', range);
        final body = StreamIterator(upstream);
        read.body = body;
        read.packets = 0;
        final span = _validate(upstream, range);
        read.offset = span.start;
        while (await _readBody(read, body)) {
          _checkCurrent();
          if (read.cancelled) throw const _RelayClosed();
          final bytes = body.current;
          if (bytes.length > end - read.offset + 1) throw const TedFailure('invalid_response');
          retained.put(read.offset, bytes);
          read.offset += bytes.length;
        }
        await body.cancel();
        read.body = null;
        if (read.offset != end + 1) throw const HttpException('interrupted next cache');
        start = read.offset;
      }
    } on _RelayStatus catch (error) {
      throw TedFailure(switch (error.status) {
        401 || 403 => 'sign_in_required',
        404 || 409 || 410 || 412 || 416 => 'source_selection_required',
        429 => 'rate_limited',
        _ => 'unavailable',
      }, retryAfter: error.retryAfter);
    } finally {
      _io(read, 'cache_fill_finished', {'offset': read.offset, 'cached_bytes': retained.bytes});
      await read.cancel();
      _active.remove(read);
    }
  }

  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _trace.event('relay_close', values: {'active_requests': _active.length});
    _cancelled.complete();
    _client.close(force: true);
    return _closing = (() async {
      await Future.wait(_active.toList().map((read) => read.cancel()));
      await _listener?.close(force: true);
    })();
  }

  void _io(_RelayRead read, String phase, [Map<String, int> values = const {}]) =>
      _trace.event(phase, request: read.id, values: values);

  Map<String, int> _rangeNumbers(String range) {
    if (range.isEmpty) return const {'start': 0, 'end': -1};
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
    if (match == null) return const {};
    return {'start': int.tryParse(match[1]!) ?? -1, 'end': int.tryParse(match[2]!) ?? -1};
  }

  Future<bool> _readBody(_RelayRead read, StreamIterator<List<int>> body) async {
    if (!_trace.active) return body.moveNext().timeout(readTimeout);
    final clock = Stopwatch()..start();
    final sampled = read.packets < 8;
    if (sampled) _io(read, 'body_wait_begin', {'upstream': read.upstream, 'offset': read.offset});
    try {
      final hasData = await body.moveNext().timeout(readTimeout);
      if (clock.elapsedMicroseconds > read.maxBodyWaitUs) read.maxBodyWaitUs = clock.elapsedMicroseconds;
      if (sampled || clock.elapsedMilliseconds >= 20 || !hasData) {
        _io(read, 'body_wait_done', {
          'upstream': read.upstream,
          'offset': read.offset,
          'wait_us': clock.elapsedMicroseconds,
          'bytes': hasData ? body.current.length : 0,
          'first': read.packets == 0 ? 1 : 0,
          'eof': hasData ? 0 : 1,
        });
      }
      read.packets++;
      return hasData;
    } catch (_) {
      _io(read, 'body_wait_failed', {
        'upstream': read.upstream,
        'offset': read.offset,
        'wait_us': clock.elapsedMicroseconds,
      });
      rethrow;
    }
  }

  Future<void> _write(_RelayRead read, HttpResponse response, List<int> bytes, {required bool cached}) async {
    if (!_trace.active) {
      response.add(bytes);
      await response.flush();
      return;
    }
    final clock = Stopwatch()..start();
    final sampled = read.writes++ < 8 || (cached ? read.cachedWrites == 0 : read.networkWrites == 0);
    final fields = {'cached': cached ? 1 : 0, 'offset': read.offset, 'bytes': bytes.length};
    if (sampled) _io(read, 'write_begin', fields);
    try {
      response.add(bytes);
      await response.flush();
      if (cached) {
        read.cachedBytes += bytes.length;
        read.cachedWrites++;
      } else {
        read.networkBytes += bytes.length;
        read.networkWrites++;
      }
      if (clock.elapsedMicroseconds > read.maxFlushUs) read.maxFlushUs = clock.elapsedMicroseconds;
      if (sampled || clock.elapsedMilliseconds >= 20) {
        _io(read, 'write_flushed', {...fields, 'wait_us': clock.elapsedMicroseconds});
      }
    } catch (_) {
      _io(read, 'write_failed', {...fields, 'wait_us': clock.elapsedMicroseconds});
      rethrow;
    }
  }
}

class _RelayRead {
  final int id;
  int upstream = 0, packets = 0, writes = 0;
  int cachedBytes = 0, cachedWrites = 0, networkBytes = 0, networkWrites = 0;
  int maxFlushUs = 0, maxBodyWaitUs = 0;
  _RelayRead(this.id);
  HttpClientRequest? request;
  StreamIterator<List<int>>? body;
  bool cancelled = false;
  bool restart = false;
  int generation = 0;
  int offset = 0;
  Future<void> interrupt() async {
    generation++;
    request?.abort();
    final active = body;
    body = null;
    try {
      await active?.cancel();
    } catch (_) {
      /* closing an already failed upstream stream */
    }
  }

  Future<void> cancel() {
    cancelled = true;
    return interrupt();
  }
}

class _RelayStatus implements Exception {
  final int status;
  final Duration? retryAfter;
  const _RelayStatus(this.status, {this.retryAfter});
  bool get retryable => status == 408 || status == 429 || status >= 500 && status <= 599;
}

class _RelayClosed implements Exception {
  const _RelayClosed();
}

class _RelayRange {
  final int start;
  final int end;
  final int size;
  const _RelayRange(this.start, this.end, this.size);
  static bool validRequest(String raw) => raw.isEmpty || RegExp(r'^bytes=(\d+-\d*|-\d+)$').hasMatch(raw);
  factory _RelayRange.request(String raw, int size) {
    if (!validRequest(raw) || size <= 0) throw const _RelayStatus(416);
    if (raw.isEmpty) return _RelayRange(0, size - 1, size);
    final parts = raw.substring(6).split('-');
    final first = int.tryParse(parts[0]);
    final last = int.tryParse(parts[1]);
    if (parts[0].isEmpty) {
      if (last == null || last <= 0) throw const _RelayStatus(416);
      return _RelayRange((size - last).clamp(0, size - 1), size - 1, size);
    }
    if (first == null || first >= size || first < 0 || last != null && last < first) throw const _RelayStatus(416);
    return _RelayRange(first, (last ?? size - 1).clamp(first, size - 1), size);
  }
}
