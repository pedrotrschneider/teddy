import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../mpv/mpv.dart';
import '../focus/transport_keys.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_local_store.dart';
import 'ted_track_languages.dart';

/// Minimal T2 adapter for Plezy's actual platform player. Source renewal always
/// reopens this session at its observed offset, never creates another release or
/// invents a new start/completion report. Full offline integration belongs to T5.
class TedPlayback extends ChangeNotifier {
  final TedClient client;
  final Player player;
  final TedPlaybackSession session;
  final Uri server;
  final int userId;
  final TedLocalStore? journal;
  final bool offline;
  final List<SubtitleTrack> localSubtitles;
  final String? scope;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<Map<String, dynamic>> _pending = [];
  Future<void> _reports = Future<void>.value();
  Future<void> _controls = Future<void>.value();
  Future<void>? _recovery;
  Future<void>? _stop;
  Timer? _progress;
  Timer? _landingWatchdog;
  Timer? _pendingEnd;
  int _playheadGeneration = 0;
  int? _checkingEndGeneration;
  Duration _lastProgressPosition = Duration.zero;
  int _idleProgressTicks = 0;
  bool _closed = false;
  final Stopwatch _startup = Stopwatch();
  bool _startupReported = false;
  bool _ready = false;
  bool _stopping = false;
  bool _completionObserved = false;
  bool _stopRecorded = false;
  Duration _position = Duration.zero;
  Duration? _openingPosition;
  Duration? _seekTarget;
  final timelinePosition = ValueNotifier<Duration>(Duration.zero);
  int _sequence = 0;
  int _reconnectsWithoutFrame = 0;
  int _prematureEnds = 0;
  int _learnedDurationMs = 0;
  bool _startReported = false;
  bool _durationRejected = false;
  String? _trackSignature;
  late String _originalLanguage = session.originalLanguage;
  TedTrackLanguages _languages = const TedTrackLanguages();
  String? _audioId;
  String? _subtitleId;
  String? _secondarySubtitleId;
  double _rate = 1;
  bool _wantsToPlay = true;
  int _controlsPending = 0;
  TedFailure? _playerFailure;
  TedFailure? _syncFailure;
  TedFailure? get failure => _syncFailure ?? _playerFailure;
  bool get ready => _ready;
  bool get loading =>
      !_closed &&
      !_stopping &&
      _playerFailure == null &&
      (!_ready || _openingPosition != null || _seekTarget != null || _recovery != null || player.state.buffering);
  bool get controlsBusy => _controlsPending > 0 || _recovery != null;
  bool get wantsToPlay => _wantsToPlay;
  bool get completedNaturally => _completionObserved;
  int get positionMs => _position.inMilliseconds;
  int get durationMs => session.durationMs > 0 ? session.durationMs : _learnedDurationMs;
  List<SubtitleTrack> get sidecars => [
    for (final sub in session.subtitles)
      SubtitleTrack.uri(
        server.resolve(sub.path).toString(),
        title: sub.label.isEmpty ? sub.language : sub.label,
        language: sub.language,
        codec: sub.codec.isEmpty ? null : sub.codec,
      ),
  ];
  TedPlayback(
    this.client,
    this.player,
    this.session, {
    this.journal,
    this.offline = false,
    this.localSubtitles = const [],
  }) : server = client.auth.offlineServer ?? client.auth.server!,
       userId = client.auth.offlineUserId ?? client.auth.userId!,
       scope = tedOfflineScope(client.auth);

  Future<void> open() async {
    if (_closed || _stopping) return;
    _subscriptions.add(
      player.streams.duration.listen((duration) {
        if (_learnedDurationMs == 0 && duration.inMilliseconds > 0) {
          _learnedDurationMs = duration.inMilliseconds.clamp(0, 604800000);
        }
        _validateDuration();
        _reportStartWhenReady();
        if (!_closed) notifyListeners();
      }),
    );
    _subscriptions.add(
      player.streams.position.listen((position) {
        if (!_ready || _stopping) return;
        // Reopening resets the native mirror before the requested start has
        // loaded. These transport zeros are not legitimate resume reports.
        // A time-pos notification can be an optimistic target or the last
        // demuxer timestamp at EOF. Only playback-restart confirms a landing.
        if (_seekTarget != null || _openingPosition != null || player.state.completed) return;
        _position = position;
        timelinePosition.value = position;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      player.streams.fileLoaded.listen((_) {
        if (_closed || _stopping) return;
        if (!_ready) {
          _ready = true;
          _position = _openingPosition ?? Duration(milliseconds: session.resumeMs);
          _validateDuration();
          _reportStartWhenReady();
        }
        _playerFailure = _durationRejected ? const TedFailure('source_placeholder') : null;
        unawaited(_applyTracks());
        notifyListeners();
      }),
    );
    _subscriptions.add(
      player.streams.completed.listen((completed) {
        _pendingEnd?.cancel();
        if (completed && _ready && !_stopping && _recovery == null) {
          if (_seekTarget != null || _openingPosition != null) {
            // Give a transient seek EOF time to clear. If it persists, recover
            // the requested position instead of leaving a blank keep-open core.
            final generation = _playheadGeneration;
            _pendingEnd = Timer(const Duration(seconds: 1), () => unawaited(_checkEnd(generation)));
          } else {
            unawaited(_checkEnd(_playheadGeneration));
          }
        }
      }),
    );
    _subscriptions.add(
      player.streams.buffering.listen((_) {
        if (!_closed) notifyListeners();
      }),
    );
    _subscriptions.add(
      player.streams.playing.listen((_) {
        if (!_closed) notifyListeners();
      }),
    );
    _subscriptions.add(
      player.streams.playbackRestart.listen((_) {
        _reconnectsWithoutFrame = 0;
        if (!_seekHasLanded()) return;
        if (!_startupReported && _startup.isRunning) {
          _startupReported = true;
          appLogger.i(
            'TED player ready: session=${session.id} offline=$offline elapsed_ms=${_startup.elapsedMilliseconds}',
          );
          _startup.stop();
        }
        _seekTarget = null;
        _openingPosition = null;
        _landingWatchdog?.cancel();
        _pendingEnd?.cancel();
        _capturePosition();
        _lastProgressPosition = _position;
        _idleProgressTicks = 0;
        if (!_closed) notifyListeners();
        if (player.state.completed) unawaited(_checkEnd(_playheadGeneration));
      }),
    );
    _subscriptions.add(
      player.streams.tracks.listen((_) {
        if (!_closed && !_stopping) unawaited(_applyTracks());
        if (!_closed) notifyListeners();
      }),
    );
    _subscriptions.add(
      player.streams.log.listen((log) {
        // Raw player diagnostics may contain URLs or headers. Keep them out of
        // Teddy logs/UI and use only this numeric status to recover access.
        if (PlayerError.httpStatusFromLog(log.text) == 401 && !_stopping && !_closed) {
          unawaited(reconnect(refreshAccess: true).catchError((Object _) {}));
        }
      }),
    );
    _subscriptions.add(
      player.streams.error.listen((error) {
        if (_closed || _stopping || _recovery != null) return;
        if (PlayerError.httpStatusFromLog(error.message) == 401) {
          unawaited(reconnect(refreshAccess: true).catchError((Object _) {}));
        } else if (_seekTarget != null && _prematureEnds++ < 2) {
          // A failed range read during a seek may terminate mpv's file. Retry
          // this pinned session at the requested offset; never advance items.
          unawaited(reconnect().catchError((Object _) {}));
        } else {
          _playerFailure = TedFailure(switch (PlayerError.httpStatusFromLog(error.message)) {
            409 => 'source_selection_required',
            422 => 'source_unsupported',
            _ => 'playback_failed',
          });
          notifyListeners();
        }
      }),
    );
    _progress = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_ready || _stopping || _closed || _playerFailure != null) return;
      _record('progress');
      if (!_wantsToPlay || _seekTarget != null || _openingPosition != null || _recovery != null) {
        _idleProgressTicks = 0;
      } else if (_position != _lastProgressPosition) {
        _idleProgressTicks = 0;
      } else if (++_idleProgressTicks >= 2) {
        // A backend can leave a valid first frame and then stop producing any
        // progress without an error/EOF. Thirty seconds without movement while
        // playback is requested is a stalled session, never a completion.
        _recoverInterrupted();
      }
      _lastProgressPosition = _position;
    });
    try {
      // Upstream Android native players read settings during initialization.
      // The TED entry does not run Plezy's main/bootstrap, so own this prerequisite.
      final settings = await SettingsService.getInstance();
      final hardware = settings.read(SettingsService.enableHardwareDecoding);
      await player.setProperty(
        'hwdec',
        hardware
            ? switch (defaultTargetPlatform) {
                // auto-safe excludes direct MediaCodec and can pick the
                // copy-back decoder, defeating Android's native video plane.
                TargetPlatform.android => 'mediacodec',
                TargetPlatform.macOS => 'videotoolbox',
                _ => 'auto-safe',
              }
            : 'no',
      );
      if (player.playerType == 'mpv') {
        // Read-ahead capacity is independent of the threshold for resuming
        // after starvation. Keep the native cache budget and fill while playing.
        await player.setProperty('cache-pause-initial', 'no');
        await player.setProperty('cache-pause-wait', '0.5');
      }
      if (journal != null && scope != null) _languages = await journal!.trackLanguages(scope!, session.media);
      if (_originalLanguage.isEmpty && !offline) unawaited(_loadOriginalLanguage());
      await _openAt(
        Duration(milliseconds: max(0, session.resumeMs - settings.read(SettingsService.rewindOnResume) * 1000)),
        play: true,
      );
    } on TedFailure catch (error) {
      _playerFailure = error;
      if (!_closed) notifyListeners();
    } catch (_) {
      _playerFailure = const TedFailure('playback_failed');
      if (!_closed) notifyListeners();
    }
  }

  Future<void> _openAt(Duration position, {required bool play}) async {
    if (_closed || _stopping) return;
    _seekTarget = null;
    _openingPosition = position;
    _startup
      ..reset()
      ..start();
    _startupReported = false;
    _playheadGeneration++;
    _idleProgressTicks = 0;
    _pendingEnd?.cancel();
    _position = position;
    timelinePosition.value = position;
    notifyListeners();
    if (offline) {
      if (journal == null || scope == null || tedOfflineScope(client.auth) != scope) {
        throw const TedFailure('sign_in_required');
      }
      _trackSignature = null;
      await player.open(
        Media(session.mediaPath, start: position),
        play: play,
        externalSubtitles: localSubtitles,
        timelineDuration: session.durationMs > 0 ? Duration(milliseconds: session.durationMs) : null,
      );
      _watchLanding();
      _position = position;
      await player.setRate(_rate);
      return;
    }
    if (_closed || _stopping) return;
    if (client.auth.server != server || client.auth.userId != userId) {
      throw const TedFailure('sign_in_required');
    }
    final headers = await client.auth.headers();
    if (_closed || _stopping) return;
    if (client.auth.server != server || client.auth.userId != userId) {
      throw const TedFailure('sign_in_required');
    }
    _trackSignature = null;
    await player.open(
      Media(server.resolve(session.mediaPath).toString(), headers: headers, start: position),
      play: play,
      externalSubtitles: sidecars,
      timelineDuration: session.durationMs > 0 ? Duration(milliseconds: session.durationMs) : null,
    );
    _watchLanding();
    _position = position;
    await player.setRate(_rate);
  }

  bool _capturePosition() {
    if (_seekTarget != null || _openingPosition != null) return false;
    final actual = player.decodedPosition;
    _position = actual;
    timelinePosition.value = actual;
    return true;
  }

  bool _seekHasLanded() {
    final target = _seekTarget ?? _openingPosition;
    return target == null || (player.decodedPosition - target).abs() <= const Duration(seconds: 2);
  }

  void _watchLanding() {
    _landingWatchdog?.cancel();
    if (_seekTarget == null && _openingPosition == null) return;
    final generation = _playheadGeneration;
    _landingWatchdog = Timer(const Duration(seconds: 15), () {
      if (_closed || _stopping || generation != _playheadGeneration || _recovery != null) return;
      if (_seekTarget != null || _openingPosition != null) _recoverInterrupted();
    });
  }

  void _recoverInterrupted() {
    if (_closed || _stopping || _recovery != null) return;
    _pendingEnd?.cancel();
    _landingWatchdog?.cancel();
    if (_prematureEnds++ < 2) {
      unawaited(reconnect().catchError((Object _) {}));
    } else {
      _playerFailure = const TedFailure('playback_interrupted');
      notifyListeners();
    }
  }

  Future<void> _checkEnd(int generation) async {
    if (_checkingEndGeneration == generation ||
        _closed ||
        _stopping ||
        _durationRejected ||
        _recovery != null ||
        generation != _playheadGeneration) {
      return;
    }
    _checkingEndGeneration = generation;
    try {
      // Observer notifications can lag the actual decoder, particularly while
      // opening/seeking. Read current EOF/seeking rather than trusting a queued
      // flag. ExoPlayer exposes its terminal state through the same properties.
      final values = await Future.wait([
        player.getProperty('eof-reached'),
        player.getProperty('seeking'),
        player.getProperty('time-pos'),
        player.getProperty('duration'),
      ]);
      if (_closed || _stopping || _recovery != null || generation != _playheadGeneration) return;
      if (values[0] != 'yes' && values[0] != 'true' || values[1] == 'yes' || values[1] == 'true') return;
      if (_seekTarget != null || _openingPosition != null || !player.state.hasRenderedFrame) {
        _recoverInterrupted();
        return;
      }
      if (player.state.buffering || !_capturePosition()) return;
      final nativePosition = double.tryParse(values[2] ?? '');
      if (nativePosition == null || !nativePosition.isFinite || nativePosition < 0 || nativePosition > 604800) return;
      _position = Duration(milliseconds: (nativePosition * 1000).round());
      final nativeDuration = double.tryParse(values[3] ?? '');
      if (durationMs == 0 && nativeDuration != null && nativeDuration.isFinite && nativeDuration > 0) {
        _learnedDurationMs = (nativeDuration * 1000).round().clamp(0, 604800000);
      }
      _validateDuration();
      if (_durationRejected || session.expectedDurationMs > 0 && _learnedDurationMs == 0) return;
      if (durationMs <= 0 && _position <= Duration.zero) return;
      if (durationMs > 0 && durationMs - _position.inMilliseconds > 2000) {
        _record('progress');
        _recoverInterrupted();
        return;
      }
      _completionObserved = true;
      unawaited(stop(naturalEof: true).catchError((Object _) {}));
    } catch (_) {
      // An unreadable native state is not evidence of completion. A pending
      // load/seek still has its bounded landing watchdog.
    } finally {
      if (_checkingEndGeneration == generation) _checkingEndGeneration = null;
    }
  }

  Future<void> _loadOriginalLanguage() async {
    try {
      final language = await client.originalLanguage(
        session.media,
        current: () => !_closed && !_stopping && tedOfflineScope(client.auth) == scope,
      );
      if (_closed || _stopping || tedOfflineScope(client.auth) != scope || language.isEmpty) return;
      _originalLanguage = language;
      _trackSignature = null;
      await _applyTracks();
    } catch (_) {
      /* Playback can use English/default while metadata is unavailable. */
    }
  }

  Future<void> _applyTracks() async {
    await _control(() async {
      await _applyCurrentTracks();
    });
  }

  Future<void> _applyCurrentTracks() async {
    final tracks = player.state.tracks;
    if (_closed || _stopping || tracks.audio.isEmpty && tracks.subtitle.isEmpty) return;
    final signature =
        '$_originalLanguage|${_languages.audio}|${_languages.subtitle}|${tracks.audio.map((t) => '${t.id}:${t.language}').join(',')}|${tracks.subtitle.map((t) => '${t.id}:${t.language}').join(',')}';
    if (_trackSignature == signature) return;
    _trackSignature = signature;
    AudioTrack? audio;
    for (final candidate in [AudioTrack.auto, ...tracks.audio]) {
      if (candidate.id == _audioId) {
        audio = candidate;
        break;
      }
    }
    audio ??= _languages.audioTrack(tracks.audio, _originalLanguage);
    SubtitleTrack? subtitle;
    for (final candidate in [SubtitleTrack.off, SubtitleTrack.auto, ...tracks.subtitle]) {
      if (candidate.id == _subtitleId) {
        subtitle = candidate;
        break;
      }
    }
    subtitle ??= _languages.subtitleTrack(tracks.subtitle);
    await player.selectAudioTrack(audio);
    if (!_closed && !_stopping) await player.selectSubtitleTrack(subtitle);
    if (!_closed && !_stopping && player.supportsSecondarySubtitles && _secondarySubtitleId != null) {
      final secondary = [SubtitleTrack.off, ...tracks.subtitle].where((t) => t.id == _secondarySubtitleId).firstOrNull;
      if (secondary != null) await player.selectSecondarySubtitleTrack(secondary);
    }
  }

  // Native control requests may reopen the HTTP stream. Keep track switches,
  // seeks and access recovery ordered, and contain rejected native commands.
  Future<void> _control(
    Future<void> Function() work, {
    String failureCode = 'playback_failed',
    bool clearTrackFailure = false,
  }) async {
    if (_closed || _stopping) return;
    _controlsPending++;
    notifyListeners();
    final operation = _controls.then((_) async {
      if (_closed || _stopping) return;
      final priorFailure = _playerFailure;
      try {
        await work();
        if (clearTrackFailure && priorFailure?.code == 'track_unavailable' && identical(_playerFailure, priorFailure)) {
          _playerFailure = null;
        }
      } on TedFailure catch (error) {
        _playerFailure = error;
      } catch (_) {
        _playerFailure = TedFailure(failureCode);
      }
    });
    _controls = operation;
    try {
      await operation;
    } finally {
      _controlsPending--;
      if (!_closed) notifyListeners();
    }
  }

  Future<bool> _ensureCurrentHeaders() async {
    if (offline) {
      if (tedOfflineScope(client.auth) != scope) throw const TedFailure('sign_in_required');
      return !_closed && !_stopping;
    }
    // Pause/seek/track commands act on the existing decoder and its read-ahead.
    // Rotating an API bearer is not a reason to reload that decoder. Future
    // media requests still carry the original token and TED enforces expiry;
    // an actual 401 triggers the bounded reconnect below at the retained offset.
    if (client.auth.server != server || client.auth.userId != userId || !client.auth.signedIn) {
      throw const TedFailure('sign_in_required');
    }
    return !_closed && !_stopping;
  }

  Future<void> selectAudioTrack(AudioTrack track) => _control(
    () async {
      if (![AudioTrack.auto, ...player.state.tracks.audio].any((candidate) => candidate.id == track.id)) {
        throw const TedFailure('track_unavailable');
      }
      _audioId = track.id;
      if (await _ensureCurrentHeaders()) {
        await player.selectAudioTrack(track);
        await _rememberLanguage(track.language, audio: true);
      }
    },
    failureCode: 'track_unavailable',
    clearTrackFailure: true,
  );

  Future<void> selectSubtitleTrack(SubtitleTrack track) => _control(
    () async {
      if (![
        SubtitleTrack.off,
        SubtitleTrack.auto,
        ...player.state.tracks.subtitle,
      ].any((candidate) => candidate.id == track.id)) {
        throw const TedFailure('track_unavailable');
      }
      _subtitleId = track.id;
      if (await _ensureCurrentHeaders()) {
        await player.selectSubtitleTrack(track);
        await _rememberLanguage(track.language, audio: false);
      }
    },
    failureCode: 'track_unavailable',
    clearTrackFailure: true,
  );

  Future<void> _rememberLanguage(String? language, {required bool audio}) async {
    final normalized = tedLanguage(language);
    if (normalized.isEmpty) return;
    _languages = TedTrackLanguages(
      audio: audio ? normalized : _languages.audio,
      subtitle: audio ? _languages.subtitle : normalized,
    );
    if (journal != null && scope != null && tedOfflineScope(client.auth) == scope) {
      await journal!.rememberTrackLanguage(scope!, session.media, normalized, audio: audio);
    }
  }

  Future<void> selectSecondarySubtitleTrack(SubtitleTrack track) => _control(
    () async {
      if (!player.supportsSecondarySubtitles ||
          ![SubtitleTrack.off, ...player.state.tracks.subtitle].any((t) => t.id == track.id)) {
        throw const TedFailure('track_unavailable');
      }
      _secondarySubtitleId = track.id;
      if (await _ensureCurrentHeaders()) await player.selectSecondarySubtitleTrack(track);
    },
    failureCode: 'track_unavailable',
    clearTrackFailure: true,
  );

  Future<void> setRate(double rate) => _control(() async {
    if (!rate.isFinite || rate < 0.25 || rate > 4) throw const TedFailure('playback_failed');
    if (await _ensureCurrentHeaders()) {
      await player.setRate(rate);
      _rate = rate;
    }
  });

  Future<void> playOrPause() => transport(TransportCommand.toggle);
  Future<void> transport(TransportCommand command) => _control(() async {
    _wantsToPlay = switch (command) {
      TransportCommand.play => true,
      TransportCommand.pause => false,
      TransportCommand.toggle => !_wantsToPlay,
    };
    _idleProgressTicks = 0;
    _lastProgressPosition = _position;
    if (await _ensureCurrentHeaders()) {
      if (_wantsToPlay) {
        await player.play();
      } else {
        await player.pause();
      }
    }
  });

  Future<void> seek(Duration position) => _control(() async {
    position = Duration(milliseconds: position.inMilliseconds.clamp(0, durationMs > 0 ? durationMs : 604800000));
    if (await _ensureCurrentHeaders()) {
      _position = position;
      _openingPosition = position;
      _seekTarget = position;
      _playheadGeneration++;
      _pendingEnd?.cancel();
      _watchLanding();
      timelinePosition.value = position;
      notifyListeners();
      try {
        await player.seek(position);
      } catch (_) {
        _seekTarget = null;
        _openingPosition = null;
        _landingWatchdog?.cancel();
        _capturePosition();
        rethrow;
      }
    }
  });

  Future<void> reconnect({bool refreshAccess = false}) {
    if (_recovery != null) return _recovery!;
    if (_closed || _stopping) return Future<void>.value();
    if (_reconnectsWithoutFrame++ >= 2) {
      _playerFailure = const TedFailure('playback_failed');
      notifyListeners();
      return Future<void>.value();
    }
    if (player.currentPosition > Duration.zero || _position == Duration.zero) _capturePosition();
    final offset = _position;
    late final Future<void> operation;
    operation =
        _control(() async {
          if (!offline) {
            if (refreshAccess) {
              await client.auth.refresh();
            } else {
              await client.auth.headers();
            }
          }
          if (!_closed && !_stopping) await _openAt(offset, play: _wantsToPlay);
        }).whenComplete(() {
          if (identical(_recovery, operation)) {
            _recovery = null;
            if (!_closed) notifyListeners();
          }
        });
    _recovery = operation;
    return operation;
  }

  void _record(String kind, {bool naturalEof = false}) {
    _validateDuration();
    if (_durationRejected || session.expectedDurationMs > 0 && _learnedDurationMs == 0) return;
    if (kind != 'start' && !naturalEof) _capturePosition();
    if (journal == null && _pending.length >= 100) {
      _syncFailure = const TedFailure('unavailable');
      if (!_closed) notifyListeners();
      return;
    }
    final position = _position.inMilliseconds.clamp(0, durationMs > 0 ? durationMs : 604800000);
    _pending.add({
      'id': const Uuid().v4(),
      'session_id': session.id,
      'sequence': ++_sequence,
      'media': session.media.toJson(),
      'kind': kind,
      'position_ms': position,
      'duration_ms': durationMs,
      'observed_at': DateTime.now().toUtc().toIso8601String(),
      'origin': offline ? 'offline' : 'live',
      'natural_eof': naturalEof,
    });
    unawaited(flush().catchError((Object _) {}));
  }

  void _validateDuration() {
    final actual = _learnedDurationMs;
    if (actual > 0 && session.expectedDurationMs > 0 && actual * 10 <= session.expectedDurationMs * 3) {
      _durationRejected = true;
      _completionObserved = false;
      _playerFailure = const TedFailure('source_placeholder');
    }
  }

  void _reportStartWhenReady() {
    if (!_ready ||
        _startReported ||
        _closed ||
        _stopping ||
        _durationRejected ||
        session.expectedDurationMs > 0 && _learnedDurationMs == 0) {
      return;
    }
    _startReported = true;
    _record('start');
  }

  Future<void> flush() {
    final next = _reports.then((_) async {
      while (_pending.isNotEmpty) {
        if (journal != null) {
          if (scope == null || tedOfflineScope(client.auth) != scope) throw const TedFailure('sign_in_required');
          await journal!.record(scope!, session, _pending.first, offline: offline);
          _pending.removeAt(0);
          continue;
        }
        if (client.auth.server != server || client.auth.userId != userId) {
          throw const TedFailure('sign_in_required');
        }
        final batch = _pending.take(20).toList();
        await client.events(batch);
        _pending.removeRange(0, batch.length);
      }
      _syncFailure = null;
      if (journal != null && scope != null && client.auth.signedIn) {
        unawaited(
          journal!
              .flush(client, scope!)
              .then(
                (_) {
                  _syncFailure = null;
                  if (!_closed) notifyListeners();
                },
                onError: (Object error) {
                  _syncFailure = const TedFailure('sync_pending');
                  if (!_closed) notifyListeners();
                },
              ),
        );
      }
      if (!_closed) notifyListeners();
    });
    _reports = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next.catchError((Object error) {
      final failure = error is TedFailure ? error : const TedFailure('unavailable');
      _syncFailure = failure;
      if (!_closed) notifyListeners();
      throw failure;
    });
  }

  Future<void> stop({bool naturalEof = false, bool markWatched = false}) {
    if (_stop != null) return _stop!;
    _progress?.cancel();
    _landingWatchdog?.cancel();
    _pendingEnd?.cancel();
    if (!_stopping) {
      _stopping = true;
      _wantsToPlay = false;
    }
    _stop =
        (() async {
          await _controls;
          if (_ready && !_stopRecorded) {
            _stopRecorded = true;
            _record(
              markWatched && session.media.playable ? 'complete' : 'stop',
              naturalEof: !markWatched && (naturalEof || _completionObserved),
            );
          }
          // A decoder that already failed can reject pause. The route may
          // still leave once its exact stop report is safely persisted/sent.
          try {
            await player.pause();
          } catch (_) {
            /* disposal stops the failed core */
          }
          await flush();
        })().catchError((Object error) {
          _stop = null;
          throw error;
        });
    return _stop!;
  }

  Future<void> closePlayer() async {
    if (_closed) return;
    _closed = true;
    _progress?.cancel();
    _landingWatchdog?.cancel();
    _pendingEnd?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _controls;
    await player.dispose();
    timelinePosition.dispose();
    dispose();
  }
}
