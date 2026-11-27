import '../utils/app_logger.dart';
import 'ted_models.dart';

const tedStartupTraceEnabled = bool.fromEnvironment('TEDDY_STARTUP_TRACE');

/// Diagnostic-only numeric events. Never accepts URLs, headers or error text.
class TedStartupTrace {
  final String session;
  final bool enabled;
  final void Function(String) _log;
  final Stopwatch _clock = Stopwatch()..start();
  final Duration Function()? elapsedOverride;
  int _events = 0;
  int _samples = 0;
  bool _sampleLimitReported = false;
  Duration _window = Duration.zero;
  int _transportEvents = 0;
  int _suppressed = 0;
  static const eventLimit = 1024;
  static const sampleLimit = 256;
  static const timeLimit = Duration(seconds: 90);
  TedStartupTrace(
    this.session, {
    this.enabled = tedStartupTraceEnabled,
    void Function(String)? log,
    this.elapsedOverride,
  }) : _log = log ?? appLogger.i;

  Duration get elapsed => elapsedOverride?.call() ?? _clock.elapsed;
  bool get active => enabled && tedUuid(session) && _events < eventLimit && elapsed <= timeLimit;

  void event(
    String phase, {
    int request = 0,
    Map<String, int> values = const {},
    bool transport = false,
    bool terminal = false,
    String? clientRequestId,
    String? serverRequestId,
  }) {
    if (!enabled || !tedUuid(session) || !RegExp(r'^[a-z_]{1,40}$').hasMatch(phase)) return;
    if (clientRequestId != null && !tedUuid(clientRequestId) || serverRequestId != null && !tedUuid(serverRequestId)) {
      return;
    }
    if (request < 0 || values.entries.any((v) => !RegExp(r'^[a-z_]{1,32}$').hasMatch(v.key))) return;
    if (values.values.any((v) => v.abs() > 9007199254740991)) return;
    final sampled =
        const {'write_begin', 'write_flushed', 'body_wait_begin', 'body_wait_done'}.contains(phase) &&
        !(phase == 'body_wait_done' && values['first'] == 1);
    if (!transport && !active) return;
    // Packet samples retain the startup budget. Whole-session milestones have
    // a renewable rate bound; a blocked-call heartbeat and one terminal record
    // per request cannot be displaced by a fragmented body or an old session.
    if (transport && !terminal && !sampled && phase != 'transport_progress') {
      if (elapsed - _window >= const Duration(minutes: 1)) {
        _window = elapsed;
        _transportEvents = 0;
      }
      if (_transportEvents++ >= 512) {
        _suppressed++;
        if (_transportEvents == 513) event('transport_events_limited', transport: true, terminal: true);
        return;
      }
    }
    if (sampled && !active) return;
    if (sampled && _samples++ >= sampleLimit) {
      if (!_sampleLimitReported) {
        _sampleLimitReported = true;
        event('trace_samples_limited', transport: transport);
      }
      return;
    }
    _events++;
    final fields = {
      ...values,
      if (terminal) 'suppressed_events': _suppressed,
    }.entries.map((v) => '${v.key}=${v.value}').join(' ');
    try {
      _log(
        'TED startup IO: phase=$phase session=$session request=$request '
        'trace_us=${elapsed.inMicroseconds} event=$_events'
        '${clientRequestId == null ? "" : " client_request_id=$clientRequestId"}'
        '${serverRequestId == null ? "" : " server_request_id=$serverRequestId"}'
        '${fields.isEmpty ? "" : " $fields"}',
      );
      if (_events == eventLimit) {
        _log('TED startup IO: phase=trace_limit session=$session events=$_events');
      }
    } catch (_) {
      // Diagnostics cannot interrupt authenticated delivery or retirement.
    }
  }
}
