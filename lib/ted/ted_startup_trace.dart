import '../utils/app_logger.dart';
import 'ted_models.dart';

const tedStartupTraceEnabled = bool.fromEnvironment('TEDDY_STARTUP_TRACE');

/// Diagnostic-only numeric events. Never accepts URLs, headers or error text.
class TedStartupTrace {
  final String session;
  final bool enabled;
  final void Function(String) _log;
  final Stopwatch _clock = Stopwatch()..start();
  int _events = 0;
  int _samples = 0;
  bool _sampleLimitReported = false;
  static const eventLimit = 1024;
  static const sampleLimit = 256;
  static const timeLimit = Duration(seconds: 90);
  TedStartupTrace(this.session, {this.enabled = tedStartupTraceEnabled, void Function(String)? log})
    : _log = log ?? appLogger.i;

  bool get active => enabled && tedUuid(session) && _events < eventLimit && _clock.elapsed <= timeLimit;

  void event(String phase, {int request = 0, Map<String, int> values = const {}}) {
    if (!active || !RegExp(r'^[a-z_]{1,40}$').hasMatch(phase)) return;
    if (request < 0 || values.entries.any((v) => !RegExp(r'^[a-z_]{1,32}$').hasMatch(v.key))) return;
    if (values.values.any((v) => v.abs() > 9007199254740991)) return;
    final sampled =
        const {'write_begin', 'write_flushed', 'body_wait_begin', 'body_wait_done'}.contains(phase) &&
        !(phase == 'body_wait_done' && values['first'] == 1);
    if (sampled && _samples++ >= sampleLimit) {
      if (!_sampleLimitReported) {
        _sampleLimitReported = true;
        event('trace_samples_limited');
      }
      return;
    }
    _events++;
    final fields = values.entries.map((v) => '${v.key}=${v.value}').join(' ');
    try {
      _log(
        'TED startup IO: phase=$phase session=$session request=$request '
        'trace_us=${_clock.elapsedMicroseconds} event=$_events${fields.isEmpty ? "" : " $fields"}',
      );
      if (_events == eventLimit) {
        _log('TED startup IO: phase=trace_limit session=$session events=$_events');
      }
    } catch (_) {
      // Diagnostics cannot interrupt authenticated delivery or retirement.
    }
  }
}
