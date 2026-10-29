import '../focus/focusable_text_field.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../mpv/mpv.dart';
import '../media/media_item.dart';
import '../providers/playback_state_provider.dart';
import '../services/settings_service.dart' as prefs;
import '../services/fullscreen_state_manager.dart';
import '../services/video_volume_controller.dart';
import '../services/video_filter_manager.dart';
import '../services/scoped_player_prefs.dart';
import '../widgets/video_controls/video_controls.dart';
import '../widgets/video_controls/player_chrome_controller.dart';
import '../widgets/video_controls/widgets/player_toast_indicator.dart';
import '../widgets/overlay_sheet.dart';
import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_playback.dart';
import 'ted_presentation.dart';
import 'ted_local_store.dart';
import 'ted_app_shutdown.dart';
import 'ted_episode_navigation.dart';
import 'ted_player_cursor.dart';
import 'ted_player_loading.dart';
import 'ted_playback_chapters.dart';
import '../utils/platform_detector.dart';
import '../utils/app_logger.dart';
import '../widgets/video_controls/player_control_scope.dart';
import '../focus/key_event_utils.dart';
import '../focus/dpad_navigator.dart';

class TeddyPlayer extends StatefulWidget {
  final TedClient client;
  final TedPlaybackSession session;
  final String title;
  final Player? player;
  final MediaItem? metadata;
  final TedLocalStore? journal;
  final bool offline;
  final List<SubtitleTrack> localSubtitles;
  final Future<TedEpisodeTargets>? episodeTargets;
  final Future<void> Function(TedTitle target)? onEpisodeTransition;
  final void Function(TedTitle target)? onPrefetchNext;
  const TeddyPlayer({
    super.key,
    required this.client,
    required this.session,
    required this.title,
    this.player,
    this.metadata,
    this.journal,
    this.offline = false,
    this.localSubtitles = const [],
    this.episodeTargets,
    this.onEpisodeTransition,
    this.onPrefetchNext,
  });
  @override
  State<TeddyPlayer> createState() => _TeddyPlayerState();
}

class _TeddyPlayerState extends State<TeddyPlayer> {
  final _routeFocus = FocusNode(debugLabel: 'TeddyPlayerRoute', canRequestFocus: false);
  OverlaySheetController? _sheet;

  KeyEventResult _handleBackKey(KeyEvent event) => handleBackKeyAction(event, () {
    if (_sheet?.isOpen ?? false) {
      _sheet!.pop();
    } else {
      unawaited(_exit());
    }
  });

  bool _backWithoutFocus(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true || !event.logicalKey.isBackKey) return false;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == _routeFocus || (primary?.ancestors.contains(_routeFocus) ?? false)) return false;
    return _handleBackKey(event) == KeyEventResult.handled;
  }

  TedAppShutdown? _shutdown;
  Future<void> _stopForExit() async {
    await _playback.stop();
    await _playback.closePlayer();
  }

  late final _playback = TedPlayback(
    widget.client,
    widget.player ??
        Player(
          useExoPlayer: prefs.SettingsService.instance.read(prefs.SettingsService.useExoPlayer),
          hardwareDecoding: prefs.SettingsService.instance.read(prefs.SettingsService.enableHardwareDecoding),
        ),
    widget.session,
    journal: widget.journal,
    offline: widget.offline,
    localSubtitles: widget.localSubtitles,
  );
  TedEpisodeTargets _targets = const TedEpisodeTargets();
  bool _seasonRemembered = false;
  bool _nextPrefetched = false;
  bool _canExit = false;
  bool _exiting = false;
  final _chrome = PlayerChromeController();
  final _toast = PlayerToastController();
  final _firstFrame = ValueNotifier(false);
  final _queue = PlaybackStateProvider();
  VideoVolumeController? _volume;
  VideoFilterManager? _filters;
  MediaItem get _metadata =>
      widget.metadata ??
      TedPresentation(widget.client).item(
        TedTitle(
          widget.session.media,
          widget.title,
          '',
          false,
          0,
          widget.session.resumeMs,
          false,
          ready: true,
          durationMs: _playback.durationMs,
        ),
      );
  StreamSubscription<void>? _frameSubscription;
  int _chapterRevision = 0;
  String? _startupError;
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_backWithoutFocus);
    _playback.addListener(_changed);
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
    _frameSubscription = _playback.player.streams.playbackRestart.listen((_) {
      _firstFrame.value = true;
      if (mounted && _chapterRevision == 0) setState(() => _chapterRevision = 1);
    });
    unawaited(_open());
    unawaited(
      widget.episodeTargets
          ?.then((targets) {
            if (mounted) setState(() => _targets = targets);
          })
          .catchError((Object _) {}),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shutdown = TedAppShutdownScope.maybeOf(context);
    _shutdown?.stopPlayback = _stopForExit;
  }

  Future<void> _open() async {
    try {
      final settings = await prefs.SettingsService.getInstance();
      if (!mounted) return;
      _volume = VideoVolumeController(
        player: _playback.player,
        settings: settings,
        initialVolume: settings.read(prefs.SettingsService.volume),
      );
      _filters = VideoFilterManager(
        player: _playback.player,
        nativeVideoZoom: Platform.isAndroid,
        initialBoxFitMode: 0,
      );
      await _playback.open();
      await _playback.setRate(ScopedPlayerPrefs.resolve(ScopedPlayerPrefs.playbackSpeed, _metadata));
      _volume!.commit(settings.read(prefs.SettingsService.volume));
      if (mounted) setState(() {});
    } catch (error) {
      appLogger.w(
        'TED player startup failed: session=${widget.session.id} '
        'backend=${_playback.player.playerType} code=${error is TedFailure ? error.code : "playback_failed"}',
      );
      if (mounted) setState(() => _startupError = const TedFailure('playback_failed').message);
    }
  }

  void _changed() {
    if (!_nextPrefetched &&
        !_exiting &&
        !widget.offline &&
        _playback.ready &&
        _playback.durationMs > 0 &&
        _playback.positionMs >= _playback.durationMs ~/ 2 &&
        widget.session.source == 'addon' &&
        widget.session.bingeKey.isNotEmpty &&
        _targets.next != null) {
      _nextPrefetched = true;
      widget.onPrefetchNext?.call(_targets.next!);
    }
    if (mounted) setState(() {});
    if (_playback.ready && !_seasonRemembered && !widget.offline && widget.journal != null && _playback.scope != null) {
      _seasonRemembered = true;
      unawaited(
        widget.journal!.rememberSeasonSource(_playback.scope!, widget.session).catchError((Object _) {
          if (mounted) setState(() => _startupError = 'Could not save the season source preference.');
        }),
      );
    }
    if (mounted &&
        _playback.completedNaturally &&
        (_playback.failure == null || _playback.failure?.code == 'sync_pending') &&
        !_exiting &&
        !_canExit) {
      final autoplay = prefs.SettingsService.instance.read(prefs.SettingsService.teddyAutoPlayNextEpisode);
      unawaited(_exit(action: autoplay ? TedPlayerAction.completed : TedPlayerAction.back));
    }
  }

  Future<void> _exit({TedPlayerAction action = TedPlayerAction.back}) async {
    if (_exiting) return;
    setState(() {
      _exiting = true;
    });
    try {
      await _playback.stop(markWatched: action == TedPlayerAction.next);
      final targets = action == TedPlayerAction.back
          ? const TedEpisodeTargets()
          : await widget.episodeTargets?.catchError((Object _) => const TedEpisodeTargets()) ?? _targets;
      final target = action == TedPlayerAction.previous ? targets.previous : targets.next;
      if (!mounted) return;
      if (action == TedPlayerAction.back &&
          prefs.SettingsService.instance.read(prefs.SettingsService.exitFullscreenOnPlayerClose) &&
          PlatformDetector.isDesktopOS()) {
        await FullscreenStateManager().exitFullscreen();
      }
      // Update the covered browse tree before popping this route. The target
      // details page owns loading, focus and Back throughout source preparation.
      if (action != TedPlayerAction.back && target != null) await widget.onEpisodeTransition?.call(target);
      if (!mounted) return;
      setState(() {
        _canExit = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pop(TedPlayerExit(action, target: action == TedPlayerAction.back ? null : target));
        }
      });
    } catch (_) {
      /* reporting failure is visible and exact events remain retryable */
    } finally {
      if (mounted) {
        setState(() {
          _exiting = false;
        });
      }
    }
  }

  Future<void> _finishCredits() async {
    await _playback.stop(markWatched: true);
    final autoplay = prefs.SettingsService.instance.read(prefs.SettingsService.teddyAutoPlayNextEpisode);
    await _exit(action: autoplay ? TedPlayerAction.completed : TedPlayerAction.back);
  }

  Future<void> _signInAgain() async {
    final username = TextEditingController();
    final password = TextEditingController();
    String? error;
    bool busy = false;
    try {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Sign in to TED again'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Use the same TED account to finish syncing this playback.'),
                FocusableTextField(
                  controller: username,
                  decoration: const InputDecoration(labelText: 'Username'),
                  autocorrect: false,
                ),
                FocusableTextField(
                  controller: password,
                  decoration: const InputDecoration(labelText: 'Password (if configured)'),
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                ),
                if (error != null) Text(error!),
              ],
            ),
            actions: [
              TextButton(onPressed: busy ? null : () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setDialogState(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await widget.client.auth.login(
                            _playback.server.toString(),
                            username.text,
                            password.text,
                            'Teddy ${Platform.operatingSystem}',
                          );
                          if (widget.client.auth.userId != _playback.userId) throw const TedFailure('sign_in_required');
                          await _playback.flush();
                          if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                        } on TedFailure catch (failure) {
                          if (dialogContext.mounted) {
                            setDialogState(() {
                              error = failure.message;
                            });
                          }
                        } catch (_) {
                          if (dialogContext.mounted) {
                            setDialogState(() {
                              error = const TedFailure('unavailable').message;
                            });
                          }
                        } finally {
                          if (dialogContext.mounted) {
                            setDialogState(() {
                              busy = false;
                            });
                          }
                        }
                      },
                child: const Text('Sign in'),
              ),
            ],
          ),
        ),
      );
    } finally {
      username.dispose();
      password.dispose();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_backWithoutFocus);
    _routeFocus.dispose();
    if (_shutdown?.stopPlayback == _stopForExit) _shutdown?.stopPlayback = null;
    unawaited(_frameSubscription?.cancel());
    _volume?.dispose();
    _filters?.dispose();
    _chrome.dispose();
    _toast.dispose();
    _queue.dispose();
    _firstFrame.dispose();
    _playback.removeListener(_changed);
    unawaited(_playback.closePlayer());
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _playback.player;
    final error = _startupError ?? _playback.failure?.message;
    final metadata = _metadata;
    return ChangeNotifierProvider.value(
      value: _queue,
      child: Focus(
        focusNode: _routeFocus,
        onKeyEvent: (_, event) => _handleBackKey(event),
        child: OverlaySheetHost(
          canPop: _canExit,
          onSystemBack: () => unawaited(_exit()),
          onOpenChanged: (open) {
            if (open) {
              _chrome.hold(PlayerChromeHold.promptInteraction);
            } else {
              _chrome.release(PlayerChromeHold.promptInteraction);
            }
          },
          child: Builder(
            builder: (context) {
              _sheet = OverlaySheetController.of(context);
              return Scaffold(
                // Native video is composited behind Flutter. Only chrome/error panels
                // paint over it; the video surface must remain transparent.
                backgroundColor: Colors.transparent,
                body: TedPlayerCursor(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _filters?.updatePlayerSize(constraints.biggest);
                            });
                            return Video(player: player);
                          },
                        ),
                      ),
                      if (_volume != null)
                        Positioned.fill(
                          child: PlayerControlScale(
                            factor: PlatformDetector.isTV() ? 1.5 : 1,
                            child: PlayerTimelinePosition(
                              position: _playback.timelinePosition,
                              duration: _playback.durationMs > 0 ? Duration(milliseconds: _playback.durationMs) : null,
                              child: PlexVideoControls(
                                player: player,
                                volumeController: _volume!,
                                metadata: metadata,
                                chromeController: _chrome,
                                toastController: _toast,
                                hasFirstFrame: _firstFrame,
                                canControl: _playback.ready && !_exiting,
                                canNavigateMediaItems: false,
                                playbackExtrasLoader: () =>
                                    tedPlaybackChapters(player, durationMs: _playback.durationMs),
                                playbackExtrasRevision: _chapterRevision,
                                onReachedEnd: ({bool skipAutoPlayCountdown = false}) {
                                  unawaited(_finishCredits());
                                },
                                onNext: _targets.next == null
                                    ? null
                                    : () => unawaited(_exit(action: TedPlayerAction.next)),
                                onPrevious: _targets.previous == null
                                    ? null
                                    : () => unawaited(_exit(action: TedPlayerAction.previous)),
                                boxFitMode: _filters?.boxFitMode ?? 0,
                                videoZoomScale: _filters?.zoomScale ?? 1,
                                onBack: () => unawaited(_exit()),
                                onSeekRequested: _playback.seek,
                                onRateRequested: _playback.setRate,
                                onPlayPauseRequested: _playback.transport,
                                onAudioTrackRequested: _playback.selectAudioTrack,
                                onSubtitleTrackRequested: _playback.selectSubtitleTrack,
                                onSecondarySubtitleTrackRequested: player.supportsSecondarySubtitles
                                    ? _playback.selectSecondarySubtitleTrack
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      if (_startupError == null && _playback.loading)
                        Positioned.fill(child: TedPlayerLoading(media: metadata)),
                      if (error != null)
                        Positioned(
                          top: MediaQuery.paddingOf(context).top + 72,
                          left: 24,
                          right: 24,
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(error),
                                  TextButton(
                                    onPressed: () async {
                                      await _playback.flush().catchError((Object _) {});
                                    },
                                    child: const Text('Retry sync'),
                                  ),
                                  TextButton(onPressed: _playback.reconnect, child: const Text('Reconnect')),
                                  if (!widget.client.auth.signedIn || widget.client.auth.userId != _playback.userId)
                                    TextButton(onPressed: _signInAgain, child: const Text('Sign in again')),
                                  TextButton(onPressed: _exiting ? null : _exit, child: const Text('Back')),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
