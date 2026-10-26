import 'ted_title_preferences_buttons.dart';
import 'ted_preparation.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../focus/input_mode_tracker.dart';
import 'ted_client.dart';
import 'ted_local_store.dart';
import 'ted_season_source.dart';
import 'ted_models.dart';
import 'ted_source_models.dart';
import 'ted_sources.dart';
import 'ted_focus_region.dart';
import 'ted_home_banner.dart';
import 'ted_play_button.dart';
import 'ted_cast_row.dart';
import 'ted_metadata_models.dart';
import 'ted_personal_thumbnail.dart';
import 'ted_downloads.dart';
import 'ted_download_button.dart';

typedef TedSelectedPlay = Future<void> Function(TedTitle title, String? sourceId, bool fromBeginning);
typedef TedSelectedDownload = Future<void> Function(TedTitle title, String? sourceId);

/// Movie details stays inside the browse shell so the rail and profile chrome
/// remain available. Provider selection never changes a saved RD mapping.
class TedMovieDetail extends StatefulWidget {
  final TedClient client;
  final TedTitle initial;
  final TedSelectedPlay onPlay;
  final TedSelectedDownload? onDownload;
  final TedDownloads? downloads;
  final VoidCallback onClose, onSidebar, onHeader;
  final double horizontalInset;
  final void Function(TedMetadataPerson, TedTitle, TedMetadataSnapshot?)? onPerson;
  const TedMovieDetail({
    super.key,
    required this.client,
    required this.initial,
    required this.onPlay,
    this.onDownload,
    this.downloads,
    required this.onClose,
    required this.onSidebar,
    required this.onHeader,
    required this.horizontalInset,
    this.onPerson,
  });
  @override
  State<TedMovieDetail> createState() => TedMovieDetailState();
}

class TedMovieDetailState extends State<TedMovieDetail> {
  final _actions = GlobalKey<TedFocusRegionState>();
  final _playFocus = FocusNode(debugLabel: 'ted_detail_play');
  final _cast = GlobalKey<TedCastRowState>();
  final _scroll = ScrollController();
  bool _revealPending = false;
  late TedTitle _title = widget.initial;
  TedTitle? _show;
  late final _episodeArtwork = TedPersonalArtwork(widget.client, loadEpisodeDetails: false);
  late TedMetadataSnapshot? _castMetadata = widget.initial.enrichment;
  bool _lastLaneCast = false;
  TedSourcePage? _mapped, _stremio;
  String _provider = 'stremio';
  String? _selected, _error, _sourceError;
  bool _loading = true, _loadingSources = false, _working = false;
  bool _mappingKnown = false;
  bool _focusOnLoad = true;
  bool _providerInitialized = false;
  TedSeasonSource? _savedSeasonSource;
  int _generation = 0;
  TedPreparation? _preparation;
  Timer? _sourceRetry;
  DateTime? _firstSourcesAt;
  void _prepareSelected() {
    final choice = _stremio?.choices.where((c) => c.id == _selected).firstOrNull;
    final eligible =
        _provider == 'stremio' &&
        choice != null &&
        (choice.favorite || choice.recentRank > 0) &&
        TedPreparation.eligible(choice);
    final id = eligible ? choice.id : null;
    if (_preparation?.sourceId == id) return;
    widget.client.discardPreparation(_preparation);
    _preparation = id == null ? null : widget.client.prepareSource(_title.media, id);
  }

  bool requestFocus() => (_lastLaneCast && (_cast.currentState?.requestFocus() ?? false)) || _focusActions();
  bool requestPlayFocus() {
    _focusOnLoad = true;
    _lastLaneCast = false;
    if (!_playable || _playFocus.context == null || ModalRoute.of(context)?.isCurrent == false) return false;
    _playFocus.requestFocus();
    _focusOnLoad = false;
    _revealActions();
    return true;
  }

  bool _focusActions() {
    _lastLaneCast = false;
    return _actions.currentState?.requestFocus() ?? false;
  }

  void _revealActions() {
    if (InputModeTracker.currentMode != InputMode.keyboard) return;
    if (_revealPending) return;
    _revealPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealPending = false;
      if (!mounted ||
          InputModeTracker.currentMode != InputMode.keyboard ||
          !_scroll.hasClients ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      if ((_scroll.offset - _scroll.position.minScrollExtent).abs() < 1) return;
      unawaited(
        _scroll.animateTo(
          _scroll.position.minScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  Widget _selectable(Widget child) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (focused) {
      if (focused) _revealActions();
    },
    child: child,
  );

  void _metadata(TedMediaIdentity media, TedMetadataSnapshot snapshot) {
    if (mounted && _title.media.kind == 'episode' && media == _show?.media && snapshot.type == 'Series') {
      if (!identical(snapshot, _show!.enrichment)) setState(() => _show = _show!.withEnrichment(snapshot));
      return;
    }
    if (!mounted ||
        media != _title.media ||
        snapshot.type != (_title.media.kind == 'episode' ? 'Episode' : 'Movie') ||
        identical(snapshot, _castMetadata)) {
      return;
    }
    // Keep usable credits during a queued refresh or provider failure; a
    // confirmed ready empty cast is still allowed to replace old credits.
    if (snapshot.people.isEmpty &&
        (snapshot.pending || snapshot.unavailable) &&
        _castMetadata?.people.isNotEmpty == true) {
      return;
    }
    setState(() {
      _castMetadata = snapshot;
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void dispose() {
    _generation++;
    _sourceRetry?.cancel();
    widget.client.discardPreparation(_preparation);
    _episodeArtwork.dispose();
    _playFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    if (_loadingSources || _working) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    // Details and source selection are independent; neither blocks the banner.
    final detail = () async {
      try {
        final title = await widget.client.title(_title.media);
        if (mounted && generation == _generation) {
          setState(() => _title = title);
          if (title.media.kind == 'episode') unawaited(_loadEpisodeMetadata(title, generation));
        }
      } catch (error) {
        if (mounted && generation == _generation) setState(() => _error = _message(error));
      }
    }();
    final sources = () async {
      try {
        final page = await widget.client.mappedSource(_title.media);
        if (!mounted || generation != _generation) return;
        setState(() {
          _mappingKnown = true;
          _mapped = page.mapped ? page : null;
          // A user-selected Stremio release survives detail/watch refreshes.
          if (!_providerInitialized || _mapped == null) {
            _provider =
                _stremio?.preferredSource != null ||
                    _savedSeasonSource?.provider == 'stremio' &&
                        _stremio != null &&
                        _savedSeasonSource!.match(_stremio!) != null
                ? 'stremio'
                : page.mapped
                ? 'mapped'
                : 'stremio';
          }
          _providerInitialized = true;
        });
        _prepareSelected();
        _focusReady();
      } catch (error) {
        if (mounted && generation == _generation) setState(() => _error = _message(error));
      }
    }();
    final parent = () async {
      if (_title.media.kind != 'episode') return;
      try {
        final show = await widget.client.title(
          _title.parent ?? TedMediaIdentity('series', _title.media.id.split(':').first),
        );
        if (mounted && generation == _generation) setState(() => _show = show);
      } catch (error) {
        if (mounted && generation == _generation) setState(() => _error = _message(error));
      }
    }();
    await Future.wait([detail, sources, _loadStremio(), parent]);
    if (mounted && generation == _generation) {
      setState(() => _loading = false);
      _focusReady();
    }
  }

  Future<void> _loadEpisodeMetadata(TedTitle title, int generation) async {
    var snapshot = title.enrichment;
    if (snapshot != null) _metadata(title.media, snapshot);
    try {
      for (var attempt = 0; snapshot?.pending == true && attempt < 20; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted || generation != _generation) return;
        snapshot = await widget.client.metadata(snapshot!.id);
        if (!mounted || generation != _generation) return;
        _metadata(title.media, snapshot);
      }
    } catch (_) {
      /* Preserve already returned episode credits/description. */
    }
  }

  void _focusReady() {
    if (!_focusOnLoad) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusOnLoad) requestPlayFocus();
    });
  }

  String _message(Object error) => error is TedFailure ? error.message : const TedFailure('unavailable').message;
  void _retainSource(TedSourcePage page) {
    _firstSourcesAt ??= DateTime.now();
    if (page.lookupUnavailable && DateTime.now().difference(_firstSourcesAt!) < const Duration(minutes: 10)) {
      final retained =
          _stremio?.choices
              .where(
                (c) =>
                    page.unavailableAddons.contains(c.addonId) &&
                    !page.choices.any(
                      (fresh) => fresh.id == c.id || c.sourceKey.isNotEmpty && fresh.sourceKey == c.sourceKey,
                    ),
              )
              .toList() ??
          [];
      if (retained.isNotEmpty) page = page.withChoices([...retained, ...page.choices]);
    }
    final old = _stremio?.choices.where((c) => c.id == _selected).firstOrNull;
    final firstLoad = old == null;
    // A transient empty provider result must not erase playable choices.
    if (page.lookupUnavailable && page.choices.isEmpty && _stremio?.choices.isNotEmpty == true) return;
    _stremio = page;
    if (page.choices.any((source) => source.id == _selected)) return;
    // Refreshed handles require a new explicit selection. Display labels do
    // not prove that an add-on returned the same release again.
    _selected =
        (old != null && old.sourceKey.isNotEmpty
            ? page.choices.where((c) => c.sourceKey == old.sourceKey).firstOrNull?.id
            : null) ??
        page.preferredSource ??
        _savedSeasonSource?.match(page) ??
        (firstLoad ? page.choices.firstOrNull?.id : null);
    if (firstLoad &&
        (page.preferredSource != null ||
            _savedSeasonSource?.provider == 'stremio' && _savedSeasonSource?.match(page) != null)) {
      _provider = 'stremio';
    }
  }

  bool get _playable =>
      !_working && _mappingKnown && (_provider == 'mapped' ? _mapped?.ready == true : _selected != null);
  bool get _hasSources => _stremio?.choices.isNotEmpty == true;
  bool get _blockingSourceLoad => _loadingSources && !_hasSources;
  String? get _source => _provider == 'stremio' ? _selected : null;

  Future<void> _switch(String provider) async {
    if (provider == _provider || _working || _blockingSourceLoad) return;
    setState(() {
      _provider = provider;
      _sourceError = null;
    });
    _prepareSelected();
    if (provider != 'stremio' || _stremio != null) return;
    await _loadStremio();
  }

  Future<void> _loadStremio({int attempt = 0, bool forceRefresh = false}) async {
    _sourceRetry?.cancel();
    var retry = false;
    if (_loadingSources) return;
    final generation = _generation;
    setState(() {
      _loadingSources = true;
      _sourceError = null;
    });
    try {
      final scope = tedOfflineScope(widget.client.auth);
      if (scope != null) _savedSeasonSource = await widget.downloads?.store.seasonSource(scope, _title.media);
      final page =
          (_stremio == null ? widget.client.takePreparedSources(_title.media) : null) ??
          await widget.client.stremioSources(_title.media, forceRefresh: forceRefresh || attempt > 0);
      retry = page.lookupUnavailable && !page.cached;
      if (mounted && generation == _generation) setState(() => _retainSource(page));
    } catch (error) {
      retry = error is TedFailure && ['unavailable', 'addon_unavailable'].contains(error.code);
      if (mounted && generation == _generation) setState(() => _sourceError = _message(error));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingSources = false);
        _prepareSelected();
        if (retry && attempt < 2) {
          _sourceRetry = Timer(Duration(seconds: attempt == 0 ? 1 : 3), () {
            if (mounted && generation == _generation && !_working) unawaited(_loadStremio(attempt: attempt + 1));
          });
        }
        _focusReady();
      }
    }
  }

  Future<void> _choose() async {
    if (_working || _blockingSourceLoad) return;
    if (!_hasSources && (_stremio == null || _sourceError != null)) await _loadStremio();
    if (!mounted || _stremio == null || !_hasSources && _sourceError != null) return;
    var pickerPage = _stremio!;
    final chosen = await chooseTedSource(
      context,
      pickerPage,
      onReload: () => widget.client.stremioSources(_title.media, forceRefresh: true),
      client: widget.client,
      onChanged: (page) {
        pickerPage = page;
        if (mounted) {
          setState(() => _retainSource(page));
          _prepareSelected();
        }
      },
    );
    if (mounted && chosen != null) {
      final original = pickerPage.choices.where((c) => c.id == chosen).firstOrNull;
      final current = _stremio!.choices
          .where(
            (c) =>
                c.id == chosen ||
                original != null && original.sourceKey.isNotEmpty && c.sourceKey == original.sourceKey,
          )
          .firstOrNull;
      setState(() {
        // A background retry can renew handles while the picker is open.
        // Match verified release identity, never its label or provider name.
        if (current == null && original != null) {
          _stremio = _stremio!.withChoices([..._stremio!.choices, original]);
        }
        _selected = current?.id ?? chosen;
      });
      _prepareSelected();
    }
  }

  Future<void> _work(Future<void> Function() action, {bool restorePlay = false}) async {
    if (_working) return;
    final restoreFocus = _actions.currentState?.hasFocus ?? false;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) {
        final title = await widget.client.title(_title.media);
        if (mounted) setState(() => _title = title);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) {
        setState(() => _working = false);
        if (restorePlay) _focusOnLoad = true;
        _focusReady();
        if (restoreFocus && FocusManager.instance.primaryFocus is FocusScopeNode) requestFocus();
      }
    }
  }

  Widget _controls() {
    final choice = _stremio?.choices.where((s) => s.id == _selected).firstOrNull;
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _selectable(
          TedPlayButton(
            focusNode: _playFocus,
            title: _title,
            onPressed: _playable ? () => _work(() => widget.onPlay(_title, _source, false), restorePlay: true) : null,
          ),
        ),
        _selectable(
          OutlinedButton.icon(
            onPressed: _playable ? () => _work(() => widget.onPlay(_title, _source, true), restorePlay: true) : null,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Start from the beginning'),
          ),
        ),
        _selectable(
          TedDownloadButton(
            downloads: widget.downloads,
            media: _title.media,
            label: 'Download',
            onPressed: _playable && widget.onDownload != null
                ? () => _work(() => widget.onDownload!(_title, _source))
                : null,
          ),
        ),
        _selectable(
          OutlinedButton.icon(
            onPressed: _working || _loading
                ? null
                : () => _work(() => widget.client.setWatched(_title, !_title.played)),
            icon: Icon(_title.played ? Icons.check_circle : Icons.check_circle_outline),
            label: Text(_title.played ? 'Mark unwatched' : 'Mark watched'),
          ),
        ),
        if (_title.media.kind == 'movie')
          _selectable(
            TedTitlePreferencesButtons(
              onFocused: _revealActions,
              client: widget.client,
              title: _title,
              onChanged: (state) => setState(() => _title = _title.withPreferences(state)),
            ),
          ),
      ],
    );
    final selectors = Row(
      children: [
        SizedBox(
          width: 164,
          child: _selectable(
            DropdownButtonFormField<String>(
              key: ValueKey('movie-source-provider:$_provider:${_mapped != null}'),
              initialValue: _provider,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Source', border: OutlineInputBorder(), isDense: true),
              items: [
                if (_mapped != null) const DropdownMenuItem(value: 'mapped', child: Text('RD Mapped')),
                const DropdownMenuItem(value: 'stremio', child: Text('Stremio')),
              ],
              onChanged: _mapped == null || _loading && !_hasSources || _working || _blockingSourceLoad
                  ? null
                  : (value) {
                      if (value != null) unawaited(_switch(value));
                    },
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Tooltip(
            message: _provider == 'mapped'
                ? _mapped?.mappedFileName ?? ''
                : choice == null
                ? ''
                : '${choice.addon}\n${choice.description}',
            child: _selectable(
              OutlinedButton(
                key: const ValueKey('movie-source-file'),
                onPressed: _provider == 'stremio' && (!_loading || _hasSources) && !_working && !_blockingSourceLoad
                    ? _choose
                    : null,
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  minimumSize: const Size(0, 52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _blockingSourceLoad
                            ? 'Loading sources…'
                            : _provider == 'mapped'
                            ? _mapped?.mappedFileName ?? 'Mapped file'
                            : choice?.name ?? 'Choose a source',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return Focus(
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) _lastLaneCast = false;
      },
      child: TedFocusRegion(
        key: _actions,
        grid: true,
        // This lane reveals the whole banner, rather than an individual control.
        scroll: false,
        autofocus: true,
        onUp: widget.onHeader,
        onDown: () => _cast.currentState?.requestFocus(),
        onLeft: () {
          _lastLaneCast = false;
          widget.onSidebar();
        },
        onBack: widget.onClose,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset, vertical: 12),
          child: LayoutBuilder(
            builder: (context, box) => box.maxWidth >= 1080
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: actions),
                      const SizedBox(width: 24),
                      SizedBox(width: 360, child: selectors),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      actions,
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerRight,
                        child: SizedBox(width: box.maxWidth.clamp(0, 420), child: selectors),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      controller: _scroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: (box.maxHeight * .70).clamp(300.0, 740.0),
            child: TedHomeBanner(
              client: widget.client,
              entries: [_show ?? _title],
              refreshEpoch: 0,
              catalogPreview: true,
              debounceEnrichment: false,
              loadDetails: false,
              showReleaseDate: true,
              releaseDate: _castMetadata?.premiereDate ?? _title.releaseDate,
              contentHorizontalInset: widget.horizontalInset,
              leadingArtwork: _title.media.kind == 'episode'
                  ? TedPersonalThumbnail(
                      artwork: _episodeArtwork,
                      title: _castMetadata == null ? _title : _title.withEnrichment(_castMetadata!),
                    )
                  : null,
              leadingAspectRatio: 16 / 9,
              detailHeading: _title.media.kind == 'episode'
                  ? 'Season ${_title.season} Episode ${_title.episode} · ${_castMetadata?.name.isNotEmpty == true ? _castMetadata!.name : _title.episodeName}'
                  : null,
              descriptionOverride: _title.media.kind == 'episode'
                  ? (_castMetadata?.overview.isNotEmpty == true ? _castMetadata!.overview : _title.description)
                  : null,
              hideEpisodeDescription: _title.media.kind == 'episode' && !_title.played,
              onPlay: (_) async {},
              onOpen: (_) async {},
              onBack: widget.onSidebar,
              onMetadata: _metadata,
            ),
          ),
          if (_loading || _working || _blockingSourceLoad) const LinearProgressIndicator(),
          _controls(),
          for (final message in [
            ?_error,
            ?_sourceError,
            if (!_loading && _provider == 'mapped' && _mapped?.ready == false) 'The mapped source is not ready.',
            if (_provider == 'stremio') ...?_stremio?.issues,
            if (!_loading && _provider == 'stremio' && _stremio != null && _stremio!.choices.isEmpty)
              _stremio!.emptyMessage,
          ])
            Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset, vertical: 8),
              child: Row(
                children: [
                  Expanded(child: Text(message)),
                  TextButton(
                    onPressed: _working || _loading
                        ? null
                        : () {
                            if (_sourceError != null || _provider == 'stremio') {
                              unawaited(_loadStremio());
                            } else {
                              unawaited(reload());
                            }
                          },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          TedCastRow(
            key: _cast,
            client: widget.client,
            people:
                (_title.media.kind == 'episode' && _castMetadata?.scopedCast != true
                        ? _show?.enrichment
                        : _castMetadata)
                    ?.people ??
                const [],
            loading: _loading || _castMetadata?.pending == true,
            horizontalInset: widget.horizontalInset,
            onUp: _focusActions,
            onLeft: widget.onSidebar,
            onBack: widget.onClose,
            onFocusChanged: (focused) {
              if (focused) _lastLaneCast = true;
            },
            onPerson: widget.onPerson == null
                ? null
                : (person) => widget.onPerson!(person, _show ?? _title, _show?.enrichment ?? _castMetadata),
          ),
          const SizedBox(height: 24),
        ],
      ),
    ),
  );
}

/// Episode playback uses the same source/action contracts as movie playback;
/// its banner and credits are explicitly episode-scoped.
class TedEpisodeDetail extends TedMovieDetail {
  const TedEpisodeDetail({
    super.key,
    required super.client,
    required super.initial,
    required super.onPlay,
    super.onDownload,
    super.downloads,
    required super.onClose,
    required super.onSidebar,
    required super.onHeader,
    required super.horizontalInset,
    super.onPerson,
  });
}
