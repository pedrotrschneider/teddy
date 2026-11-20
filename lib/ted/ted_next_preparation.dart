import 'dart:async';
import '../models/next_episode_matching_strategy.dart';
import '../utils/app_logger.dart';
import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_preparation.dart';
import 'ted_source_models.dart';
import 'ted_next_match.dart';

enum TedNextPhase { lookup, matching, warming, caching, ready, details, retrying, blocked, discarded }

/// One successor with independent server/device retries and one active attempt.
/// A matched release remains pinned through every preparation retry.
class TedNextPreparation {
  final TedClient client;
  final TedTitle target;
  final TedPlaybackSession current;
  final NextEpisodeMatchingStrategy strategy;
  final TedSourceChoice? origin;
  final Future<void> Function(TedNextPreparation)? cache;
  final Future<void> Function(TedNextPreparation)? serverWarm;
  final Duration retryDelay;
  final _abort = Completer<void>();
  final Uri? _server;
  final int? _user;
  final String? _family;
  final _phaseTime = Stopwatch()..start();
  Timer? _retry;
  Timer? _sourceRetry;
  Future<TedSourcePage>? _sourceAttempt;
  bool _discarded = false, _warmed = false, _lookedUp = false;
  TedPreparation? _preparation;
  TedSourceChoice? selected;
  bool mapped = false;
  TedPlaybackSession? preparedSession;
  bool _handedOff = false;
  void handoff() {
    _handedOff = true;
    _retry?.cancel();
    _sourceRetry?.cancel();
    if (!_abort.isCompleted) _abort.complete();
  }

  TedNextPhase phase = TedNextPhase.lookup;
  Future<String?>? _attempt;
  Completer<void> _serverSignal = Completer<void>();
  Future<void> get serverPrepared => _serverSignal.future;
  TedNextPreparation(
    this.client,
    this.target,
    this.current, {
    this.strategy = NextEpisodeMatchingStrategy.bingeGroup,
    this.origin,
    this.cache,
    this.serverWarm,
    this.retryDelay = const Duration(minutes: 1),
  }) : _server = client.auth.server,
       _user = client.auth.userId,
       _family = client.auth.familyId {
    unawaited(_run());
  }
  bool get active =>
      !_discarded &&
      !_handedOff &&
      client.auth.signedIn &&
      client.auth.server == _server &&
      client.auth.userId == _user &&
      client.auth.familyId == _family;
  Future<void> get aborted => _abort.future;
  bool get serverReady => active && _warmed;
  Future<void> get cancellation => _preparation?.discarded ?? Future<void>.value();
  Future<void> cancelEffects() {
    _preparation?.discard();
    return cancellation;
  }

  void retryDeviceCache() {
    if (!active || !_warmed || phase == TedNextPhase.caching) return;
    _phase(TedNextPhase.retrying, 'next_cache_evicted');
    _retry?.cancel();
    _retry = Timer(retryDelay, () {
      if (active) {
        _attempt = null;
        unawaited(_run());
      }
    });
  }

  Future<String?> get source => _attempt ?? _run();

  void _phase(TedNextPhase value, [String code = 'none']) {
    final previous = phase;
    phase = value;
    appLogger.i(
      'TED next preparation: phase=${value.name} previous=${previous.name} elapsed_ms=${_phaseTime.elapsedMilliseconds} media=${target.media.kind}/${target.media.id} code=$code',
    );
    _phaseTime
      ..reset()
      ..start();
  }

  Future<String?> _run() {
    if (_attempt != null) return _attempt!;
    _retry?.cancel();
    _serverSignal = Completer<void>();
    return _attempt = _load();
  }

  Future<TedSourcePage> _sources() => _sourceAttempt ??= _lookupSources().whenComplete(() => _sourceAttempt = null);
  Duration _delay(Object error) => error is TedFailure && error.retryAfter != null && error.retryAfter! > retryDelay
      ? error.retryAfter!
      : retryDelay;
  void _retrySources([Duration? delay]) {
    _sourceRetry?.cancel();
    if (!active) return;
    _sourceRetry = Timer(delay ?? retryDelay, () {
      if (active) unawaited(_sources().then<void>((_) {}, onError: (Object _) {}));
    });
  }

  Future<TedSourcePage> _lookupSources() async {
    final refresh = _lookedUp;
    _lookedUp = true;
    try {
      final page = await client.stremioSources(
        target.media,
        forceRefresh: refresh,
        preferredAddonId: current.addonId,
        abortTrigger: aborted,
      );
      if (active) {
        client.stagePreparedSources(target.media, page);
        if (page.lookupUnavailable) _retrySources();
      }
      return page;
    } catch (error) {
      if (error is! TedFailure ||
          !const {
            'sign_in_required',
            'incompatible_version',
            'stremio_not_linked',
            'stremio_credentials_rejected',
            'stremio_link_changed',
          }.contains(error.code)) {
        _retrySources(_delay(error));
      }
      rethrow;
    }
  }

  Future<String?> _load() async {
    if (!active) {
      discard();
      if (!_serverSignal.isCompleted) _serverSignal.complete();
      return null;
    }
    try {
      if (!_warmed) {
        if (selected == null) {
          _phase(TedNextPhase.lookup);
          _phase(TedNextPhase.matching);
          if (current.source != 'addon' && strategy != NextEpisodeMatchingStrategy.manual) {
            // An unavailable Stremio connection must not block a valid mapping.
            unawaited(_sources().then<void>((_) {}, onError: (Object _) {}));
            final mapping = await client.mappedSource(target.media);
            if (!active) return null;
            if (!mapping.mapped) {
              _phase(TedNextPhase.details);
              return null;
            }
            if (!mapping.ready) throw const TedFailure('mapping_not_ready');
            mapped = true;
          } else {
            final page = await _sources();
            if (!active) return null;
            if (strategy == NextEpisodeMatchingStrategy.manual) {
              _phase(TedNextPhase.details);
              return null;
            }
            selected = matchNextRelease(current, page, strategy, origin: origin);
            if (selected == null) throw const TedFailure('next_source_unmatched');
          }
        }
        _phase(TedNextPhase.warming);
        if (selected != null) {
          _preparation ??= client.prepareSource(target.media, selected!.id, allowAdd: true);
          await _preparation!.retry();
        }
        if (mapped || cache != null || serverWarm != null) {
          preparedSession ??= await client.createCacheSession(
            target.media,
            sourceId: selected?.id,
            abortTrigger: aborted,
          );
        }
        if (serverWarm != null) await serverWarm!(this);
        if (!active) return null;
        _warmed = true;
      }
      if (!_serverSignal.isCompleted) _serverSignal.complete();
      if (cache != null) {
        _phase(TedNextPhase.caching);
        await cache!(this);
      }
      if (!active) return null;
      _phase(TedNextPhase.ready);
      return selected?.id;
    } catch (error) {
      if (!active) return null;
      final code = error is TedFailure ? error.code : 'unavailable';
      if (code == 'source_preparation_unavailable') {
        _warmed = false;
        preparedSession = null;
        _preparation?.invalidate();
      }
      if (const {
        'mapping_not_ready',
        'source_selection_required',
        'sign_in_required',
        'rd_credentials',
        'rd_not_configured',
      }.contains(code)) {
        _warmed = false;
      }
      final retryable = !const {
        'sign_in_required',
        'incompatible',
        'incompatible_version',
        'rd_credentials',
        'rd_not_configured',
        'rd_infringing',
        'rd_rejected',
        'source_archive',
        'source_placeholder',
        'source_selection_required',
        'stremio_not_linked',
        'stremio_credentials_rejected',
        'stremio_link_changed',
        'source_unsupported',
      }.contains(code);
      _phase(retryable ? TedNextPhase.retrying : TedNextPhase.blocked, code);
      if (retryable) {
        _retry = Timer(_delay(error), () {
          if (active) {
            _attempt = null;
            unawaited(_run());
          } else {
            discard();
          }
        });
      }
      return null;
    } finally {
      if (!_serverSignal.isCompleted) _serverSignal.complete();
    }
  }

  void discard() {
    if (_discarded) return;
    _discarded = true;
    _retry?.cancel();
    _sourceRetry?.cancel();
    if (!_abort.isCompleted) _abort.complete();
    client.discardPreparation(_preparation);
    _phase(TedNextPhase.discarded);
  }
}
