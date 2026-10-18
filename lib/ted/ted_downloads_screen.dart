import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/focusable_wrapper.dart';
import '../focus/input_mode_tracker.dart';
import 'ted_app_bar.dart';
import 'ted_downloads.dart';
import 'ted_download_tree.dart';
import 'ted_bulk_downloads.dart';
import 'ted_focus_region.dart';
import 'ted_models.dart';
import 'ted_player_screen.dart';
import 'ted_episode_navigation.dart';
import 'ted_app_shutdown.dart';
import '../widgets/watched_indicator.dart';
import '../services/settings_service.dart';
import '../widgets/settings_builder.dart';
import 'ted_spoiler.dart';

class TedDownloadsScreen extends StatefulWidget {
  final TedDownloads downloads;
  final bool embedded;
  final double horizontalInset;
  final VoidCallback? onSidebar, onHeader, onReady;
  final Future<void> Function(Map<String, dynamic>)? onPlay;
  const TedDownloadsScreen({
    super.key,
    required this.downloads,
    this.embedded = false,
    this.horizontalInset = 24,
    this.onSidebar,
    this.onHeader,
    this.onReady,
    this.onPlay,
  });
  @override
  State<TedDownloadsScreen> createState() => TedDownloadsScreenState();
}

class TedDownloadsScreenState extends State<TedDownloadsScreen> {
  List<TedDownloadNode> _tree = [];
  final _expanded = <String>{};
  final _nodes = <String, FocusNode>{}, _trash = <String, FocusNode>{};
  final _actionFocus = <String, FocusNode>{};
  final _regions = <String, GlobalKey<TedFocusRegionState>>{};
  final _toolbar = GlobalKey<TedFocusRegionState>();
  final _artAttempts = <String, DateTime>{};
  String? _remembered, _error;
  int _pending = 0, _artActive = 0;
  int _storageRevision = -1;
  bool _loading = false, _again = false, _working = false;
  Timer? _refresh;
  List<TedDownloadNode> get _visible {
    final values = <TedDownloadNode>[];
    void visit(TedDownloadNode node) {
      values.add(node);
      if (_expanded.contains(node.id)) {
        for (final child in node.children) {
          visit(child);
        }
      }
    }

    for (final node in _tree) {
      visit(node);
    }
    return values;
  }

  @override
  void initState() {
    super.initState();
    widget.downloads.addListener(_changed);
    unawaited(widget.downloads.refreshProgress());
    unawaited(reload());
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(reload()));
  }

  void _changed() {
    if (!mounted) return;
    if (_storageRevision != widget.downloads.storageRevision) {
      _storageRevision = widget.downloads.storageRevision;
      unawaited(reload());
    } else {
      setState(() {}); // in-flight progress never rescans every device file
    }
  }

  Future<void> reload() async {
    if (_loading) {
      _again = true;
      return;
    }
    _loading = true;
    final owner = widget.downloads.scope;
    try {
      final files = await widget.downloads.list(), queued = await widget.downloads.queueEntries();
      final sizes = <String, int>{};
      for (final file in files) {
        sizes[file['id'] as String] = await widget.downloads.diskBytes(file);
      }
      final count = owner == null ? 0 : await widget.downloads.store.pending(owner);
      final watches = await widget.downloads.watchStates(files);
      if (mounted && owner == widget.downloads.scope) {
        setState(() {
          _tree = tedDownloadTree(widget.downloads, files, queued, sizes, watches: watches);
          _pending = count;
        });
        for (final file in files) {
          final id = file['id'] as String;
          if (_artActive >= 5 || DateTime.now().difference(_artAttempts[id] ?? DateTime(1970)).inSeconds < 30) continue;
          _artAttempts[id] = DateTime.now();
          _artActive++;
          unawaited(
            widget.downloads.cacheFolderArtwork(file).catchError((Object _) {}).whenComplete(() {
              _artActive--;
            }),
          );
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Device storage could not be read.');
    } finally {
      _loading = false;
      if (mounted) widget.onReady?.call();
      if (_again && mounted) {
        _again = false;
        unawaited(reload());
      }
    }
  }

  bool requestFocus({bool first = false}) {
    if (first && _loading) return false;
    final rows = _visible;
    final node = first ? rows.firstOrNull : rows.where((v) => v.id == _remembered).firstOrNull ?? rows.firstOrNull;
    if (node == null) return _toolbar.currentState?.requestFocus() ?? false;
    _focus(node.id);
    return true;
  }

  void _focus(String id) {
    final node = _nodes[id];
    if (node != null) {
      _remembered = id;
      node.requestFocus();
      _reveal(node);
    }
  }

  void _move(String id, bool up) {
    final rows = _visible, i = _visible.indexWhere((v) => v.id == id);
    final target = i + (up ? -1 : 1);
    if (target >= 0 && target < rows.length) {
      _focus(rows[target].id);
    } else if (up) {
      _toolbar.currentState?.requestFocus();
    }
  }

  void _reveal(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          InputModeTracker.currentMode != InputMode.keyboard ||
          !node.hasFocus ||
          node.context == null ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      Scrollable.ensureVisible(
        node.context!,
        alignment: .4,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _work(Future<void> Function() work) async {
    if (_working) return;
    setState(() {
      _error = null;
      _working = true;
    });
    try {
      await work();
    } on TedFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Device storage or download operation failed.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
    await reload();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          (_visible.every((v) => v.id != _remembered) || FocusManager.instance.primaryFocus?.context == null)) {
        requestFocus();
      }
    });
  }

  Future<void> _play(Map<String, dynamic> value) async {
    if (widget.onPlay != null) {
      await widget.onPlay!(value);
      return;
    }
    final manager = widget.downloads;
    var current = value;
    while (mounted) {
      final session = await manager.offlineSession(current);
      if (!mounted || (TedAppShutdownScope.maybeOf(context)?.closing ?? false)) return;
      manager.beginPlaying(current['id'] as String);
      TedPlayerExit? result;
      try {
        result = await Navigator.of(context).push<TedPlayerExit>(
          MaterialPageRoute(
            builder: (_) => TeddyPlayer(
              client: manager.client,
              session: session,
              title: manager.metadata(current).title ?? session.media.id,
              metadata: manager.metadata(current),
              journal: manager.store,
              offline: true,
              localSubtitles: manager.sidecarTracks(current),
              episodeTargets: manager.offlineTargets(session.media),
            ),
          ),
        );
      } finally {
        manager.endPlaying(current['id'] as String);
      }
      if (!mounted || result == null || result.action == TedPlayerAction.back || result.target == null) return;
      final files = await manager.list();
      final next = files
          .where(
            (file) =>
                TedMediaIdentity.fromJson(Map<String, dynamic>.from(file['media'] as Map)) == result!.target!.media,
          )
          .firstOrNull;
      if (next == null) return;
      current = next;
    }
  }

  Widget _row(TedDownloadNode node) {
    final focus = _nodes.putIfAbsent(node.id, () => FocusNode(debugLabel: 'download-${node.id}'));
    final trash = _trash.putIfAbsent(node.id, () => FocusNode(debugLabel: 'delete-${node.id}'));
    final region = _regions.putIfAbsent(node.id, GlobalKey<TedFocusRegionState>.new);
    final saved = node.saved, queued = node.queued;
    final status = saved?['status'] ?? queued?['status'];
    final progress = widget.downloads.progress(
      node.expandable ? TedMediaIdentity('series', node.id.split(':')[0]) : node.media!,
      season: node.kind == 'season' ? int.parse(node.id.split(':')[1]) : null,
    );
    void select() {
      if (node.expandable) {
        setState(() {
          _expanded.contains(node.id) ? _expanded.remove(node.id) : _expanded.add(node.id);
        });
      } else if (saved?['status'] == 'complete') {
        unawaited(_work(() => _play(saved!)));
      }
    }

    final narrow = MediaQuery.sizeOf(context).width < 700;
    final imageWidth = node.kind == 'episode' ? (narrow ? 96.0 : 192.0) : (narrow ? 64.0 : 80.0);
    final imageHeight = node.kind == 'episode' ? (narrow ? 54.0 : 108.0) : (narrow ? 96.0 : 120.0);
    final actions = <Widget>[
      if (node.hasFailures) ...[
        _failureAction(node, 'retry', 'Retry', () => widget.downloads.retryFailed(node.identities)),
        _failureAction(node, 'source', 'Change selected source', () async {
          await chooseTedBulkDownloads(context, widget.downloads, failed: node.identities);
        }),
      ],
      if (saved != null && (status == 'downloading' || status == 'queued'))
        TextButton(
          onPressed: _working ? null : () => _work(() => widget.downloads.pause(saved['id'] as String)),
          child: const Text('Pause'),
        ),
      if (saved != null && status != 'complete' && status != 'downloading' && status != 'queued' && !node.hasFailures)
        TextButton(
          onPressed: _working ? null : () => _work(() => widget.downloads.resumeDownload(saved)),
          child: const Text('Resume'),
        ),
      if (saved == null && queued != null && status != 'queued' && !node.hasFailures)
        TextButton(
          onPressed: _working ? null : () => _work(() => widget.downloads.retryQueued(queued)),
          child: const Text('Retry'),
        ),
      if (saved != null && (saved['missing_assets'] as List?)?.isNotEmpty == true)
        TextButton(
          onPressed: _working ? null : () => _work(() => widget.downloads.retryAssets(saved)),
          child: const Text('Retry artwork/subtitles'),
        ),
    ];
    return Padding(
      key: ValueKey('download-row-${node.id}'),
      padding: EdgeInsets.only(left: node.depth * (narrow ? 24.0 : 48.0), bottom: 12),
      child: TedFocusRegion(
        key: region,
        scroll: false,
        onUp: () => _move(node.id, true),
        onDown: () => _move(node.id, false),
        onLeft: widget.onSidebar,
        onBack: widget.onSidebar,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: FocusableWrapper(
                    focusNode: focus,
                    disableScale: true,
                    autoScroll: false,
                    descendantsAreFocusable: false,
                    onSelect: _working ? null : select,
                    onFocusChange: (active) {
                      if (active) {
                        _remembered = node.id;
                        _reveal(focus);
                      }
                    },
                    onKeyEvent: (_, event) {
                      if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
                      final key = event.logicalKey;
                      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
                        _move(node.id, key == LogicalKeyboardKey.arrowUp);
                        return KeyEventResult.handled;
                      }
                      if (key == LogicalKeyboardKey.arrowRight) {
                        region.currentState?.requestNext(focus);
                        return KeyEventResult.handled;
                      }
                      if (key == LogicalKeyboardKey.arrowLeft) {
                        if (event is KeyDownEvent) {
                          widget.onSidebar?.call();
                        }
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    onBack: widget.onSidebar,
                    child: InkWell(
                      onTap: _working ? null : select,
                      canRequestFocus: false,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 28,
                              child: node.expandable
                                  ? Icon(_expanded.contains(node.id) ? Icons.expand_more : Icons.chevron_right)
                                  : null,
                            ),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: imageWidth,
                                height: imageHeight,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    node.artwork == null
                                        ? ColoredBox(
                                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                            child: Icon(
                                              node.kind == 'episode' ? Icons.play_arrow : Icons.movie_outlined,
                                              size: 32,
                                            ),
                                          )
                                        : TedSpoiler(
                                            unwatchedEpisode: node.kind == 'episode' && !node.currentlyWatched,
                                            child: Image.file(
                                              File(node.artwork!),
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) => const Icon(Icons.movie_outlined),
                                            ),
                                          ),
                                    SettingsBuilder(
                                      prefs: const [SettingsService.showWatchedIndicators],
                                      builder: (_) => WatchedIndicator(
                                        item: node.indicatorItem,
                                        size: WatchedIndicatorSize.compact,
                                        showUnwatchedCount: true,
                                        showUnviewedCount: true,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    node.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleLarge,
                                  ),
                                  if (node.kind == 'episode')
                                    Text('S${node.media!.id.split(':')[1]} E${node.media!.id.split(':')[2]}'),
                                  Text(tedDiskSize(node.bytes), style: Theme.of(context).textTheme.bodyMedium),
                                  if (progress != null && (node.expandable || progress.pending)) ...[
                                    Text(progress.label),
                                    if (!node.expandable && progress.status == 'downloading') Text(progress.speed),
                                  ] else if (status != null && status != 'complete')
                                    Text(
                                      '$status${saved == null ? '' : ' · ${tedDiskSize(saved['received'] as int)} / ${tedDiskSize(saved['bytes'] as int)}'}',
                                    ),
                                  if ((saved?['error'] ?? queued?['error']) != null)
                                    Text(TedFailure((saved?['error'] ?? queued?['error']) as String).message),
                                  if (progress?.pending == true)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: LinearProgressIndicator(value: progress!.fraction),
                                    )
                                  else if (saved != null && status != 'complete')
                                    LinearProgressIndicator(
                                      value: (saved['received'] as int) / (saved['bytes'] as int),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (!narrow) ...actions,
                IconButton(
                  focusNode: trash,
                  tooltip: node.kind == 'show'
                      ? 'Delete all downloaded episodes of this series'
                      : node.kind == 'season'
                      ? 'Delete all downloaded episodes of this season'
                      : 'Delete device copy',
                  onPressed: _working ? null : () => _work(() => widget.downloads.removeSelection(node.identities)),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (narrow && actions.isNotEmpty) Wrap(spacing: 8, children: actions),
          ],
        ),
      ),
    );
  }

  Widget _failureAction(TedDownloadNode node, String key, String label, Future<void> Function() action) {
    final focus = _actionFocus.putIfAbsent('${node.id}:$key', () => FocusNode(debugLabel: '$key-${node.id}'));
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused && InputModeTracker.currentMode == InputMode.keyboard) {
          _remembered = node.id;
          _reveal(focus);
        }
      },
      child: TextButton(
        focusNode: focus,
        key: ValueKey('download-$key-${node.id}'),
        onPressed: _working
            ? null
            : () => _work(() async {
                await action();
                if (mounted && InputModeTracker.currentMode == InputMode.keyboard) _focus(node.id);
              }),
        child: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: EdgeInsets.fromLTRB(widget.horizontalInset, widget.embedded ? 96 : 20, widget.horizontalInset, 20),
      children: [
        TedFocusRegion(
          key: _toolbar,
          scroll: false,
          onUp: widget.onHeader,
          onDown: requestFocus,
          onLeft: widget.onSidebar,
          onBack: widget.onSidebar,
          child: Row(
            children: [
              Expanded(child: Text('$_pending playback reports waiting to sync.')),
              TextButton(
                onPressed: _working
                    ? null
                    : () => _work(() async {
                        final scope = widget.downloads.scope;
                        if (scope == null) throw const TedFailure('sign_in_required');
                        await widget.downloads.store.flush(widget.downloads.client, scope);
                      }),
                child: const Text('Sync history'),
              ),
            ],
          ),
        ),
        if (_working) const LinearProgressIndicator(),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (widget.downloads.policyError != null)
          Text(widget.downloads.policyError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (widget.downloads.storageError != null)
          Text(widget.downloads.storageError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_tree.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No downloads for this account on this device. Open a movie, series, season or episode and select Download.',
            ),
          ),
        for (final node in _visible) _row(node),
      ],
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: const TedAppBar(title: Text('Downloads')),
            body: body,
          );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    widget.downloads.removeListener(_changed);
    for (final node in [..._nodes.values, ..._trash.values, ..._actionFocus.values]) {
      node.dispose();
    }
    super.dispose();
  }
}
