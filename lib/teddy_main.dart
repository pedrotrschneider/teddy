import 'ted/ted_profile_screen.dart';
import 'ted/ted_secure_storage_recovery.dart';
import 'ted/ted_source_cache.dart';
import 'ted/ted_home_cache.dart';
import 'ted/ted_next_preparation.dart';
import 'ted/ted_preparing_player.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'database/app_database.dart';
import 'ted/ted_local_store.dart';
import 'ted/ted_downloads.dart';
import 'ted/ted_bulk_downloads.dart';
import 'ted/ted_downloads_screen.dart';

import 'package:flutter/material.dart';
import 'focus/input_mode_tracker.dart';
import 'focus/key_event_utils.dart';
import 'services/settings_service.dart' as prefs;
import 'theme/mono_theme.dart';
import 'widgets/settings_builder.dart';
import 'ted/ted_auth.dart';
import 'ted/ted_client.dart';
import 'ted/ted_sources.dart';
import 'ted/ted_app_settings.dart';
import 'ted/teddy_logs.dart';
import 'ted/ted_browse_screen.dart';
import 'ted/ted_presentation.dart';
import 'ted/ted_profiles.dart';
import 'ted/ted_models.dart';
import 'ted/ted_player_screen.dart';
import 'ted/ted_app_bar.dart';
import 'ted/ted_app_shutdown.dart';
import 'ted/ted_focus_recovery.dart';
import 'ted/ted_episode_navigation.dart';
import 'ted/ted_season_source.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _TeddyStartup());
}

class _TeddyStartup extends StatefulWidget {
  const _TeddyStartup();
  @override
  State<_TeddyStartup> createState() => _TeddyStartupState();
}

class _TeddyStartupState extends State<_TeddyStartup> {
  bool _ready = false, _failed = false;
  bool _exiting = false, _exitFailed = false;
  TedLocalStore? _store;
  Directory? _downloadRoot;
  String? _deviceId;
  late final _shutdown = TedAppShutdown(closeStorage: () async => _store?.close());
  late final AppLifecycleListener _lifecycle;
  Future<void>? _startup;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _requestExit);
    unawaited(_startup = _start());
  }

  Future<AppExitResponse> _requestExit() async {
    if (mounted) {
      setState(() {
        _exiting = true;
        _exitFailed = false;
      });
    }
    final result = await _shutdown.requestExit(startup: _startup);
    if (mounted && result == AppExitResponse.cancel) setState(() => _exitFailed = true);
    return result;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _failed = false);
    try {
      final settings = await prefs.SettingsService.getInstance();
      await initializeTeddyPlatform(settings).timeout(const Duration(seconds: 20));
      final support = await getApplicationSupportDirectory();
      await TeddyLogs.initialize(support);
      _store ??= TedLocalStore(
        (await AppDatabase.open(databaseFile: File(p.join(support.path, 'ted-offline.sqlite')))).database,
      );
      await _store!.recoverInterrupted();
      _deviceId = await _store!.installationDevice();
      _downloadRoot = Directory(p.join(support.path, 'ted-downloads'));
      if (mounted && !_exiting) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) => TedAppShutdownScope(
    shutdown: _shutdown,
    child: Stack(
      textDirection: TextDirection.ltr,
      children: [
        ExcludeFocus(
          excluding: _exiting,
          child: AbsorbPointer(
            absorbing: _exiting,
            child: _ready
                ? TeddyApp(store: _store!, downloadRoot: _downloadRoot!, deviceId: _deviceId!)
                : MaterialApp(
                    theme: monoTheme(dark: true),
                    home: Scaffold(
                      body: Center(
                        child: _failed
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'Teddy could not initialize settings, device storage or platform controls. Existing data has been preserved.',
                                  ),
                                  FilledButton(
                                    onPressed: () => unawaited(_startup = _start()),
                                    child: const Text('Retry'),
                                  ),
                                ],
                              )
                            : const CircularProgressIndicator(),
                      ),
                    ),
                  ),
          ),
        ),
        if (_exiting)
          Positioned.fill(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: ColoredBox(
                color: const Color(0xff101010),
                child: Center(
                  child: _exitFailed
                      ? const Text(
                          'Shutdown has not finished. Press Quit again to retry.',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        )
                      : const CircularProgressIndicator(),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class TeddyApp extends StatefulWidget {
  final TedLocalStore store;
  final Directory downloadRoot;
  final String deviceId;
  const TeddyApp({super.key, required this.store, required this.downloadRoot, required this.deviceId});
  @override
  State<TeddyApp> createState() => _TeddyAppState();
}

class _TeddyAppState extends State<TeddyApp> {
  final _focusRoutes = TedFocusRoutes();
  final _backKeys = BackKeySuppressorObserver();
  @override
  Widget build(BuildContext context) => SettingsBuilder(
    prefs: const [prefs.SettingsService.themeMode],
    builder: (context) {
      final mode = prefs.SettingsService.instance.read(prefs.SettingsService.themeMode);
      return InputModeTracker(
        child: MaterialApp(
          title: 'Teddy',
          navigatorObservers: [_focusRoutes, _backKeys],
          builder: (context, child) => TedFocusRecovery(routes: _focusRoutes, child: child!),
          theme: monoTheme(dark: false),
          darkTheme: monoTheme(dark: true, oled: mode == prefs.ThemeMode.oled),
          themeMode: switch (mode) {
            prefs.ThemeMode.system => ThemeMode.system,
            prefs.ThemeMode.light => ThemeMode.light,
            _ => ThemeMode.dark,
          },
          home: TeddyHome(store: widget.store, downloadRoot: widget.downloadRoot, deviceId: widget.deviceId),
        ),
      );
    },
  );
}

class TeddyHome extends StatefulWidget {
  final TedLocalStore store;
  final Directory downloadRoot;
  final String deviceId;
  final TedProfiles? profiles;
  const TeddyHome({super.key, required this.store, required this.downloadRoot, required this.deviceId, this.profiles});
  @override
  State<TeddyHome> createState() => _TeddyHomeState();
}

class _TeddyHomeState extends State<TeddyHome> {
  var _browseKey = GlobalKey<TedBrowseScreenState>();
  late final _profiles = widget.profiles ?? TedProfiles();
  late TedAuth _auth = TedAuth(store: _profiles.connection(), deviceId: widget.deviceId);
  TedProfileSnapshot _savedProfiles = const TedProfileSnapshot(null, []);
  bool _showProfiles = true, _serverReadOnly = false;
  String? _profileServer;
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  late TedClient _client = TedClient(
    _auth,
    sourceCache: TedSourceCache(widget.store.db),
    homeCache: TedHomeCache(widget.store.db),
  );
  late TedDownloads _downloads = TedDownloads(_client, widget.store, widget.downloadRoot);
  Timer? _sync;
  Future<void>? _restoration;
  TedAppShutdown? _shutdown;
  Future<void> _stopServices() async {
    _sync?.cancel();
    // Cancels network work without signing out or deleting saved credentials.
    _auth.close();
    await _restoration;
    await _downloads.shutdown();
    await TeddyLogs.close();
  }

  int _catalogEpoch = 0;
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _profiles.addListener(_storageChanged);
    unawaited(_restoration = _restore());
    _sync = Timer.periodic(const Duration(seconds: 30), (_) => _syncHistory());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shutdown = TedAppShutdownScope.maybeOf(context);
    _shutdown?.stopServices = _stopServices;
  }

  void _syncHistory() {
    if (_profiles.accessUnavailable || _showProfiles) return;
    _downloads.pumpQueue();
    unawaited(_downloads.applyPolicies().catchError((Object _) {}));
    if (_shutdown?.closing ?? false) return;
    final scope = tedOfflineScope(_auth);
    if (scope != null && _auth.signedIn) unawaited(widget.store.flush(_client, scope).catchError((Object _) {}));
  }

  void _storageChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _retrySecureStorage() {
    if (_busy) return Future.value();
    return _restoration = _work(() async {
      await _pauseProfile();
      await _profiles.retryAccess();
      _newConnection();
      _showProfiles = false;
      await _restoreState();
    });
  }

  Future<void> _restore() => _work(_restoreState);
  Future<void> _restoreState() async {
    await _downloads.recover();
    if ((await _profiles.read()).profiles.any((p) => p.purging)) {
      await _recoverProfilePurges();
      _newConnection();
      await _downloads.recover();
    }
    _savedProfiles = await _profiles.read();
    final active = _savedProfiles.profiles.where((p) => p.key == _savedProfiles.active && !p.purging).firstOrNull;
    _profileServer = active?.server ?? _savedProfiles.profiles.where((p) => !p.purging).firstOrNull?.server;
    // Restore credentials and start account work only after an explicit choice.
    // Keep the last active key solely to remember the selected server.
    _showProfiles = true;
    await widget.store.retainDevice(widget.deviceId);
  }

  Future<void> _work(Future<void> Function() work) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on TedFailure catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = const TedFailure('unavailable').message;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => _catalogEpoch++);
  }

  void _restartLayout() {
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    setState(() => _browseKey = GlobalKey<TedBrowseScreenState>());
  }

  void _openSettings() {
    final browse = _browseKey.currentState;
    if (browse != null) {
      browse.openSettings();
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TeddySettingsScreen(onLayoutRestart: _restartLayout, downloads: _downloads),
      ),
    );
  }

  Future<void> _login() => _work(() async {
    await _auth.login(_server.text, _username.text, _password.text, 'Teddy ${Platform.operatingSystem}');
    await _downloads.recover();
    _downloads.startPolicies();
    _password.clear();
    _savedProfiles = await _profiles.read();
    _profileServer = _auth.server.toString();
    _showProfiles = false;
    _browseKey = GlobalKey<TedBrowseScreenState>();
    await _load();
    _syncHistory();
  });
  Future<void> _recoverProfilePurges() async {
    final saved = await _profiles.read();
    for (final profile in saved.profiles.where((p) => p.purging)) {
      await _downloads.purgeProfile(profile.scope);
      await _profiles.finishPurge(profile.key);
    }
  }

  Future<void> _pauseProfile() async {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    final scope = tedOfflineScope(_auth);
    final rows = scope == null ? <Map<String, dynamic>>[] : await widget.store.downloads(scope);
    final running = rows.where((r) => r['status'] == 'downloading').map((r) => r['id']).toSet();
    // Close the outgoing HTTP owner before constructing another authenticated
    // connection. Wait for refresh/storage and transfer checkpoints to settle.
    await _auth.suspend();
    await _downloads.shutdown();
    try {
      await widget.store.settle();
    } catch (_) {
      /* Reports remain durable. */
    }
    if (scope != null) {
      for (final row in await widget.store.downloads(scope)) {
        if (running.contains(row['id']) && row['status'] != 'complete') {
          row['profile_paused'] = true;
          await widget.store.saveDownload(scope, row);
        }
      }
    }
  }

  void _newConnection([String? key]) {
    _auth.close();
    _downloads.dispose();
    _auth = TedAuth(store: _profiles.connection(key), deviceId: widget.deviceId);
    _client = TedClient(_auth, sourceCache: TedSourceCache(widget.store.db), homeCache: TedHomeCache(widget.store.db));
    _downloads = TedDownloads(_client, widget.store, widget.downloadRoot);
    _browseKey = GlobalKey<TedBrowseScreenState>();
  }

  Future<void> _switchProfile({bool changeServer = false}) async {
    _profileServer = _auth.server?.toString() ?? _auth.offlineServer?.toString() ?? _profileServer;
    setState(() => _showProfiles = true);
    await _pauseProfile();
    await _profiles.activate(null);
    _savedProfiles = await _profiles.read();
    _newConnection();
    if (changeServer) {
      _serverReadOnly = false;
      _server.clear();
      _username.clear();
      _password.clear();
      _showProfiles = false;
    }
  }

  Future<void> _selectProfile(TedSavedProfile profile) => _work(() async {
    await _pauseProfile();
    await _profiles.activate(profile.key);
    _newConnection(profile.key);
    _profileServer = profile.server;
    _server.text = profile.server;
    _serverReadOnly = true;
    await _downloads.recover();
    _showProfiles = false;
    try {
      await _auth.restore();
    } finally {
      _downloads.startPolicies();
    }
    await _load();
    _syncHistory();
    final scope = tedOfflineScope(_auth);
    if (scope != null) {
      for (final row in await widget.store.downloads(scope)) {
        if (row.remove('profile_paused') == true) {
          await widget.store.saveDownload(scope, row);
          unawaited(_downloads.resume(row).catchError((Object _) {}));
        }
      }
    }
  });

  Future<void> _addProfile() => _work(() async {
    await _pauseProfile();
    await _profiles.activate(null);
    _newConnection();
    _server.text = _profileServer ?? '';
    _serverReadOnly = _profileServer != null;
    _username.clear();
    _password.clear();
    _showProfiles = false;
  });

  Future<void> _signOut() async {
    _profileServer = _auth.server?.toString() ?? _auth.offlineServer?.toString() ?? _profileServer;
    setState(() => _showProfiles = true);
    // Preserve the credential owner until logout records its secure tombstone.
    await _downloads.shutdown();
    try {
      await widget.store.settle();
    } catch (_) {}
    try {
      await _auth.logout();
    } catch (_) {
      // The verified purge marker is checked below. Remote failure must not
      // leave signed-out downloads accessible; storage failure stays visible.
    }
    await _auth.suspend();
    final pending = await _profiles.read();
    if (pending.active != null) throw const TedFailure('storage_unavailable');
    await _recoverProfilePurges();
    _savedProfiles = await _profiles.read();
    _newConnection();
    _username.clear();
    _password.clear();
  }

  Widget _profileChooser() => TedProfileScreen(
    snapshot: _savedProfiles,
    server: _profileServer,
    busy: _busy,
    error: _error,
    onSelect: _selectProfile,
    onAdd: _addProfile,
    onServer: (server) => setState(() => _profileServer = server),
    onChangeServer: () => _work(() => _switchProfile(changeServer: true)),
  );

  Future<void> _download(TedTitle title) => _downloadWithSource(title);

  Future<void> _downloadSelected(TedTitle title, String? sourceId) => _downloadWithSource(title, sourceId: sourceId);

  Future<void> _downloadWithSource(TedTitle title, {String? sourceId}) async {
    String? source = sourceId;
    if (source == null && !title.ready) {
      final page = await _client.sources(title.media);
      if (!mounted) return;
      if (page.mapped) {
        if (!page.ready) throw const TedFailure('mapping_not_ready');
      } else {
        source = page.autoSelect ?? page.preferredSource ?? await chooseTedSource(context, page, client: _client);
        if (source == null || !mounted) return;
      }
    }
    final session = await _client.createSession(title.media, sourceId: source);
    await _downloads.add(title, session);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Download added. Open Downloads to see progress.')));
    }
  }

  Future<void> _play(TedTitle title) => _playWithSource(title);

  Future<void> _playSelected(TedTitle title, String? sourceId, bool fromBeginning) =>
      _playWithSource(title, sourceId: sourceId, fromBeginning: fromBeginning, restoreSeasonSource: false);

  bool _playbackFlow = false;
  Future<void> _playWithSource(
    TedTitle title, {
    String? sourceId,
    bool fromBeginning = false,
    bool restoreSeasonSource = true,
  }) async {
    if (_playbackFlow) return;
    _playbackFlow = true;
    try {
      await _runPlayback(
        title,
        sourceId: sourceId,
        fromBeginning: fromBeginning,
        restoreSeasonSource: restoreSeasonSource,
      );
    } finally {
      _playbackFlow = false;
    }
  }

  Future<void> _runPlayback(
    TedTitle title, {
    String? sourceId,
    bool fromBeginning = false,
    bool restoreSeasonSource = true,
  }) async {
    if (_shutdown?.closing ?? false) return;
    var current = title;
    TedSeasonSource? continuation;
    while (mounted) {
      String? source = sourceId;
      try {
        final scope = tedOfflineScope(_auth);
        final preference =
            continuation ??
            (!restoreSeasonSource || scope == null ? null : await widget.store.seasonSource(scope, current.media));
        if (source == null && preference?.provider == 'stremio') {
          final page = await _client.stremioSources(current.media);
          source = continuation != null ? preference!.match(page) : page.preferredSource ?? preference!.match(page);
          if (source == null && continuation != null) {
            return;
          }
          if (!mounted) return;
          if (source == null && !current.ready) source = await chooseTedSource(context, page, client: _client);
          if (source == null && !current.ready) return;
        }
        if (source == null && continuation?.provider == 'mapped') {
          final page = await _client.mappedSource(current.media);
          if (!page.mapped || !page.ready) {
            return;
          }
        } else if (source == null && !current.ready) {
          final page = await _client.sources(current.media);
          if (!mounted) return;
          if (page.mapped) {
            if (!page.ready) throw const TedFailure('mapping_not_ready');
          } else {
            source = page.autoSelect ?? page.preferredSource ?? await chooseTedSource(context, page, client: _client);
            if (source == null || !mounted) return;
          }
        }
        if (continuation != null && _browseKey.currentState?.hasPlaybackEpisode(current.media) != true) return;
        final preparationAbort = Completer<void>();
        final sessionFuture = _client.createSelectedSession(
          current.media,
          sourceId: source,
          fromBeginning: fromBeginning,
          abortTrigger: preparationAbort.future,
        );
        // Keep immediate authentication failures observed until the route's
        // FutureBuilder attaches, while still presenting that same error there.
        unawaited(sessionFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
        if (!mounted || (_shutdown?.closing ?? false)) return;
        if (continuation != null && _browseKey.currentState?.hasPlaybackEpisode(current.media) != true) return;
        final playingTitle = current;
        TedNextPreparation? nextPreparation;
        final result = await Navigator.of(context).push<TedPlayerExit>(
          MaterialPageRoute(
            builder: (_) => TedPreparingPlayer(
              session: sessionFuture,
              metadata: TedPresentation(_client).item(playingTitle),
              player: (session) => TeddyPlayer(
                client: _client,
                session: session,
                onPrefetchNext: (target) {
                  nextPreparation ??= TedNextPreparation(_client, target, session);
                },
                title: playingTitle.name,
                metadata: TedPresentation(_client).item(playingTitle),
                journal: widget.store,
                episodeTargets: playingTitle.media.kind == 'episode'
                    ? _client.adjacentEpisodes(playingTitle.media)
                    : null,
                onEpisodeTransition: (target) async => _browseKey.currentState?.openPlaybackEpisode(target),
              ),
            ),
          ),
        );
        if (!mounted || result == null || result.action == TedPlayerAction.back || result.target == null) {
          preparationAbort.complete();
          nextPreparation?.discard();
          return;
        }
        final preparedSource = nextPreparation?.target.media == result.target!.media
            ? await nextPreparation?.source
            : null;
        if (!mounted || _browseKey.currentState?.hasPlaybackEpisode(result.target!.media) != true) {
          nextPreparation?.discard();
          return;
        }
        if (preparedSource == null) nextPreparation?.discard();
        final session = await sessionFuture;
        continuation = TedSeasonSource.fromSession(session);
        current = result.target!;
        sourceId = preparedSource;
        fromBeginning = false;
      } catch (_) {
        if (continuation != null && mounted) {
          return;
        }
        rethrow;
      }
    }
  }

  @override
  void dispose() {
    if (_shutdown?.stopServices == _stopServices) _shutdown?.stopServices = null;
    _sync?.cancel();
    _auth.close();
    _profiles.removeListener(_storageChanged);
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: _auth.signedIn && !_showProfiles
        ? null
        : TedAppBar(
            title: const Text('Teddy'),
            actions: [
              if (_auth.offlineServer != null)
                IconButton(
                  tooltip: 'Downloads',
                  icon: const Icon(Icons.download_outlined),
                  onPressed: () => Navigator.of(
                    context,
                  ).push<void>(MaterialPageRoute(builder: (_) => TedDownloadsScreen(downloads: _downloads))),
                ),
              if (_auth.offlineServer != null && !_auth.signedIn)
                TextButton(onPressed: _busy ? null : () => _work(_signOut), child: const Text('Sign out')),
              IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.settings_outlined)),
            ],
          ),
    body: _profiles.accessUnavailable
        ? TedSecureStorageRecovery(busy: _busy, onRetry: _retrySecureStorage)
        : _showProfiles
        ? _profileChooser()
        : _auth.signedIn
        ? Stack(
            children: [
              Positioned.fill(
                child: TedBrowseScreen(
                  key: _browseKey,
                  refreshEpoch: _catalogEpoch,
                  client: _client,
                  downloads: _downloads,
                  onPlay: _play,
                  onDownload: _download,
                  onPlaySelection: _playSelected,
                  onDownloadSelection: _downloadSelected,
                  onDownloadShow: (title) async {
                    final count = await chooseTedBulkDownloads(context, _downloads, show: title);
                    if (context.mounted && count != null && count > 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$count episodes queued. Open Downloads to see progress.')),
                      );
                    }
                  },
                  onDownloadSeason: (title, season) async {
                    final count = await chooseTedBulkDownloads(context, _downloads, show: title, season: season);
                    if (context.mounted && count != null && count > 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$count episodes queued. Open Downloads to see progress.')),
                      );
                    }
                  },
                  displayName: _auth.displayName ?? '',
                  onSettings: _openSettings,
                  onLayoutRestart: _restartLayout,
                  onSwitchProfile: _busy ? null : () => _work(() => _switchProfile()),
                  onChangeServer: _busy ? null : () => _work(() => _switchProfile(changeServer: true)),
                  onSignOut: _busy ? null : () => _work(_signOut),
                ),
              ),
              if (_busy) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
              if (_error != null)
                Positioned(
                  bottom: 16,
                  left: 24,
                  right: 24,
                  child: Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
                    ),
                  ),
                ),
            ],
          )
        : Column(
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: AutofillGroup(
                    child: Column(
                      children: [
                        TextField(
                          controller: _server,
                          readOnly: _serverReadOnly,
                          decoration: const InputDecoration(labelText: 'TED server', hintText: 'https://ted.example'),
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _username,
                          autofillHints: const [AutofillHints.username],
                          decoration: const InputDecoration(labelText: 'Username'),
                          autocorrect: false,
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _password,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(labelText: 'Password (if configured)'),
                          onSubmitted: (_) {
                            if (!_busy) unawaited(_login());
                          },
                        ),
                        const SizedBox(height: 24),
                        FilledButton(onPressed: _busy ? null : _login, child: const Text('Sign in')),
                        if (_savedProfiles.profiles.any((p) => !p.purging))
                          TextButton(
                            onPressed: _busy ? null : () => setState(() => _showProfiles = true),
                            child: const Text('Saved profiles'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
  );
}
