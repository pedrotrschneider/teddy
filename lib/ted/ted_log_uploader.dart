import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/log_redaction_manager.dart';
import 'ted_auth.dart';
import 'ted_local_store.dart';
import 'ted_models.dart';
import 'ted_version.dart';
import 'teddy_logs.dart';

/// Best-effort, profile-scoped diagnostics. Never owns or rotates credentials;
/// all requests use the same TedAuth owner as playback and viewing reports.
class TedLogUploader {
  final TedLocalStore store;
  final TedAuth Function() auth;
  final bool Function() active;
  final SettingsService settings;
  final DateTime Function() now;
  final Duration interval;
  final String platform, version;
  final Future<Map<String, dynamic>> Function(TedAuth, Map<String, dynamic>, Future<void>)? send;
  final _pending = <Map<String, dynamic>>[];
  Future<void> _writes = Future.value();
  Future<void>? _sending;
  Completer<void>? _abort;
  Timer? _timer, _persistTimer;
  String? _scope;
  TedAuth? _owner;
  int _generation = 0, _failures = 0, _pendingBytes = 0, _queuedBytes = 0;
  bool _closed = false, _paused = true;
  DateTime? _retryAt;
  DateTime? _lastWarning;
  late final ValueListenable<bool> _enabled = settings.listenable(SettingsService.sendDiagnosticLogs);
  static const queueBytes = 8 << 20;
  static const globalQueueBytes = 32 << 20;
  static const batchBytes = 64 << 10;
  void _warn(String phase) {
    if (_lastWarning != null && now().difference(_lastWarning!) < const Duration(minutes: 1)) return;
    _lastWarning = now();
    appLogger.w('TED diagnostics: phase=$phase');
  }

  TedLogUploader({
    required this.store,
    required this.auth,
    required this.active,
    required this.settings,
    DateTime Function()? now,
    this.interval = const Duration(seconds: 15),
    String? platform,
    String? version,
    this.send,
  }) : now = now ?? DateTime.now,
       platform = platform ?? Platform.operatingSystem,
       version = version ?? teddyReleaseVersion {
    _enabled.addListener(_settingChanged);
    TeddyLogs.addSink(capture);
    _timer = Timer.periodic(interval, (_) {
      resume();
      unawaited(flush());
    });
    if (!_enabled.value) _settingChanged();
  }
  bool get _captureAllowed =>
      !_closed &&
      !_paused &&
      _enabled.value &&
      active() &&
      _scope != null &&
      identical(_owner, auth()) &&
      tedOfflineScope(auth()) == _scope;
  void resume() {
    if (_closed || !active()) return;
    final owner = auth(), scope = tedOfflineScope(auth());
    if (scope == null) return;
    if (!_paused && identical(_owner, owner) && scope == _scope) return;
    // Snapshot pending entries with their original scope before rebinding.
    // Explicit profile transitions also await pause(), but implicit auth
    // changes must be fenced independently.
    unawaited(_persistPending());
    _abortRequest();
    _generation++;
    _paused = false;
    _owner = owner;
    _scope = scope;
    _retryAt = null;
    _failures = 0;
    appLogger.i('TED device: phase=profile_active platform=$platform version=$version log_upload=${_enabled.value}');
  }

  void _settingChanged() {
    if (_enabled.value) {
      resume();
      return;
    }
    _generation++;
    _pending.clear();
    _pendingBytes = 0;
    _persistTimer?.cancel();
    _abortRequest();
    _writes = _writes
        .then((_) async {
          await store.db.customStatement('DELETE FROM ted_log_batches');
        })
        .catchError((Object _) {
          _warn('queue_write_failed');
        });
  }

  void _abortRequest() {
    if (_abort?.isCompleted == false) _abort!.complete();
  }

  Future<void> pause() async {
    _paused = true;
    _generation++;
    _abortRequest();
    _persistTimer?.cancel();
    await _persistPending();
    _scope = null;
    _owner = null;
  }

  Future<void> close() async {
    if (_closed) return;
    _timer?.cancel();
    _persistTimer?.cancel();
    TeddyLogs.removeSink(capture);
    _enabled.removeListener(_settingChanged);
    await pause();
    _closed = true;
  }

  static final _url = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false);
  static final _session = RegExp(r'\bsession=([a-fA-F0-9-]{36})\b');
  static String safe(String value, int maxBytes) {
    final text = LogRedactionManager.redact(value).replaceAll(_url, '[url]');
    final bytes = utf8.encode(text);
    return bytes.length <= maxBytes ? text : utf8.decode(bytes.take(maxBytes).toList(), allowMalformed: true);
  }

  void capture(LogEntry entry) {
    if (!_captureAllowed) return;
    final level = entry.level.name;
    if (!const ['debug', 'info', 'warning', 'error', 'fatal'].contains(level)) return;
    final label = entry.message.split(':').first.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
    final component = label.isNotEmpty && label.length <= 48 ? label : 'app';
    if (component == 'ted_diagnostics') return; // Upload failures never generate uploads of themselves.
    var message = safe('${entry.message}${entry.error == null ? '' : ' ${entry.error}'}', 6144);
    if (entry.stackTrace != null) message = safe('$message\n${entry.stackTrace}', 8000);
    final item = <String, dynamic>{
      'id': const Uuid().v4(),
      'at': entry.timestamp.toUtc().toIso8601String(),
      'level': level,
      'component': component,
      'message': message,
    };
    final session = _session.firstMatch(entry.message)?.group(1);
    if (session != null && tedUuid(session)) item['session_id'] = session;
    final size = utf8.encode(jsonEncode(item)).length;
    if (_pending.length >= 100 || _pendingBytes + size > batchBytes) {
      unawaited(_persistPending());
    }
    // Persist is serialized. Refuse additional memory pressure while disk work is slow.
    if (_pending.length >= 100 || _pendingBytes + size > batchBytes) return;
    _pending.add(item);
    _pendingBytes += size;
    _persistTimer ??= Timer(const Duration(seconds: 10), () {
      _persistTimer = null;
      unawaited(_persistPending());
    });
    if (level == 'error' || level == 'fatal') {
      _persistTimer?.cancel();
      _persistTimer = Timer(const Duration(milliseconds: 100), () {
        _persistTimer = null;
        unawaited(_persistPending());
      });
    }
  }

  Future<void> _persistPending() {
    _persistTimer?.cancel();
    _persistTimer = null;
    final scope = _scope, entries = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();
    _pendingBytes = 0;
    if (entries.isEmpty || scope == null || !_enabled.value) return _writes;
    final payload = jsonEncode({
      'batch_id': const Uuid().v4(),
      'device_name': 'Teddy $platform',
      'platform': platform,
      'app_version': version,
      'entries': entries,
    });
    final id = jsonDecode(payload)['batch_id'] as String;
    final bytes = utf8.encode(payload).length;
    if (_queuedBytes + bytes > 256 << 10) return _writes;
    _queuedBytes += bytes;
    final created = now().millisecondsSinceEpoch;
    return _writes = _writes
        .then((_) async {
          if (!_enabled.value || _closed) return;
          await store.db.transaction(() async {
            await store.db.customStatement(
              'INSERT INTO ted_log_batches(id,scope,payload,created_ms,bytes) VALUES(?,?,?,?,?)',
              [id, scope, payload, created, bytes],
            );
            await store.db.customStatement('DELETE FROM ted_log_batches WHERE created_ms<?', [
              created - 7 * 24 * 3600 * 1000,
            ]);
            // Keep newest bytes, independently per profile and across the installation.
            await store.db.customStatement(
              'DELETE FROM ted_log_batches WHERE id IN (SELECT id FROM (SELECT id,SUM(bytes) OVER(PARTITION BY scope ORDER BY created_ms DESC,rowid DESC) own,SUM(bytes) OVER(ORDER BY created_ms DESC,rowid DESC) total FROM ted_log_batches) WHERE own>? OR total>?)',
              [queueBytes, globalQueueBytes],
            );
          });
        })
        .catchError((Object _) {
          _warn('queue_write_failed');
        })
        .whenComplete(() {
          _queuedBytes -= bytes;
        });
  }

  Future<void> flush() {
    if (_sending != null) return _sending!;
    late Future<void> operation;
    operation = _flush()
        .catchError((Object _) {
          _warn('queue_read_failed');
        })
        .whenComplete(() {
          if (identical(_sending, operation)) _sending = null;
        });
    return _sending = operation;
  }

  Future<void> _flush() async {
    await _persistPending();
    if (!_captureAllowed || !auth().signedIn || _retryAt != null && now().isBefore(_retryAt!)) return;
    final owner = auth(), scope = _scope!, generation = _generation;
    await store.db.customStatement('DELETE FROM ted_log_batches WHERE created_ms<?', [
      now().subtract(const Duration(days: 7)).millisecondsSinceEpoch,
    ]);
    for (var n = 0; n < 4; n++) {
      if (!_captureAllowed || generation != _generation) return;
      final row = await store.db
          .customSelect(
            'SELECT id,payload FROM ted_log_batches WHERE scope=? ORDER BY created_ms,rowid LIMIT 1',
            variables: [Variable(scope)],
          )
          .getSingleOrNull();
      if (row == null) return;
      if (!_captureAllowed || generation != _generation || !identical(owner, auth())) return;
      final id = row.read<String>('id');
      late Map<String, dynamic> payload;
      try {
        payload = jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      } catch (_) {
        _warn('corrupt_batch_discarded');
        await store.db.customStatement('DELETE FROM ted_log_batches WHERE id=? AND scope=?', [id, scope]);
        continue;
      }
      final abort = Completer<void>();
      _abort = abort;
      try {
        final ack =
            await (send?.call(owner, payload, abort.future) ?? owner.uploadLogs(payload, abortTrigger: abort.future));
        if (!_captureAllowed || generation != _generation || !identical(owner, auth())) return;
        if (ack['accepted'] != true || ack['batch_id'] != id) throw const TedFailure('invalid_response');
        await store.db.customStatement('DELETE FROM ted_log_batches WHERE id=? AND scope=?', [id, scope]);
        _failures = 0;
        _retryAt = null;
      } catch (error) {
        if (!_captureAllowed || generation != _generation) return;
        if (error is TedFailure && error.code == 'diagnostics_invalid') {
          _warn('invalid_batch_discarded');
          await store.db.customStatement('DELETE FROM ted_log_batches WHERE id=? AND scope=?', [id, scope]);
          continue;
        }
        _failures = math.min(_failures + 1, 8);
        final delay = error is TedFailure && error.code == 'diagnostics_unsupported'
            ? const Duration(hours: 1)
            : error is TedFailure && error.retryAfter != null
            ? error.retryAfter!
            : Duration(seconds: math.min(15 * (1 << (_failures - 1)), 900));
        _retryAt = now().add(delay);
        _warn(
          error is TedFailure && error.code == 'diagnostics_unsupported' ? 'server_upgrade_required' : 'upload_delayed',
        );
        return;
      } finally {
        if (identical(_abort, abort)) _abort = null;
      }
    }
  }
}
