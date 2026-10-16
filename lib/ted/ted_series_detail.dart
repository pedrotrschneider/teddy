import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../focus/locked_hub_controller.dart';
import '../focus/input_mode_tracker.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../services/settings_service.dart' show EpisodePosterMode;
import '../widgets/hub_section.dart';
import 'ted_client.dart';
import 'ted_dates.dart';
import 'ted_models.dart';
import 'ted_series_models.dart';
import 'ted_metadata_models.dart';
import 'ted_focus_region.dart';
import 'ted_home_banner.dart';
import 'ted_cast_row.dart';
import 'ted_personal_thumbnail.dart';
import 'ted_presentation.dart';
import 'ted_downloads.dart';
import 'ted_download_button.dart';

void _revealDetailShelf(HubSectionState? hub) {
  if (hub == null ||
      !hub.mounted ||
      !hub.hasFocus ||
      InputModeTracker.currentMode != InputMode.keyboard ||
      ModalRoute.of(hub.context)?.isCurrent == false) {
    return;
  }
  final scroll = Scrollable.maybeOf(hub.context);
  final shelf = hub.context.findRenderObject();
  final viewport = scroll?.context.findRenderObject();
  if (scroll == null ||
      shelf is! RenderBox ||
      viewport is! RenderBox ||
      !shelf.attached ||
      !viewport.attached ||
      !shelf.hasSize ||
      !viewport.hasSize ||
      !scroll.position.hasContentDimensions) {
    return;
  }
  // Reveal as much of the hero as possible while keeping the complete row,
  // including captions and focus chrome, above a small bottom margin.
  final bottom = shelf.localToGlobal(Offset(0, shelf.size.height), ancestor: viewport).dy;
  final position = scroll.position;
  final target = (position.pixels + bottom - viewport.size.height + 8).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if ((target - position.pixels).abs() < 1) return;
  unawaited(position.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic));
}

class TedSeriesDetail extends StatefulWidget {
  final TedClient client;
  final TedTitle initial;
  final double horizontalInset;
  final VoidCallback onClose, onSidebar, onHeader;
  final ValueChanged<int> onSeason;
  final Future<void> Function(TedTitle)? onDownload;
  final TedDownloads? downloads;
  final void Function(TedMetadataPerson, TedTitle, TedMetadataSnapshot?) onPerson;
  const TedSeriesDetail({
    super.key,
    required this.client,
    required this.initial,
    required this.horizontalInset,
    required this.onClose,
    required this.onSidebar,
    required this.onHeader,
    required this.onSeason,
    this.onDownload,
    this.downloads,
    required this.onPerson,
  });
  @override
  State<TedSeriesDetail> createState() => TedSeriesDetailState();
}

class TedSeriesDetailState extends State<TedSeriesDetail> {
  final _scroll = ScrollController();
  final _actions = GlobalKey<TedFocusRegionState>();
  final _seasons = GlobalKey<HubSectionState>();
  final _cast = GlobalKey<TedCastRowState>();
  final _memory = HubFocusMemory();
  late final _artwork = _SeasonArtwork(widget.client, widget.initial);
  late TedTitle _title = widget.initial;
  late TedMetadataSnapshot? _metadata = widget.initial.enrichment;
  TedSeriesWatch? _watch;
  bool _loading = true, _working = false, _focusOnLoad = true;
  String _lane = 'seasons';
  String? _error;
  int _generation = 0;
  bool _seasonsRevealPending = false;
  TedTitle get title => _title;
  bool requestFocus() => switch (_lane) {
    'cast' => (_cast.currentState?.requestFocus() ?? false) || _focusSeasons(),
    'seasons' => _focusSeasons(),
    _ => (_actions.currentState?.requestFocus() ?? false) || _focusSeasons(),
  };
  bool _focusSeasons() {
    final state = _seasons.currentState;
    if (state == null || _title.seasons.isEmpty) return false;
    state.requestFocusFromMemory();
    return true;
  }

  void _top() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted &&
        InputModeTracker.currentMode == InputMode.keyboard &&
        _scroll.hasClients &&
        ModalRoute.of(context)?.isCurrent != false &&
        _scroll.offset > 1) {
      unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic));
    }
  });
  void _revealSeasons() {
    if (_seasonsRevealPending) return;
    _seasonsRevealPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _seasonsRevealPending = false;
      if (mounted) _revealDetailShelf(_seasons.currentState);
    });
  }

  Widget _selectable(Widget child) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (value) {
      if (value) {
        _lane = 'actions';
        _top();
      }
    },
    child: child,
  );
  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void dispose() {
    _generation++;
    _artwork.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    await Future.wait([
      () async {
        try {
          final title = await widget.client.title(_title.media);
          if (mounted && gen == _generation) {
            setState(() {
              _title = title;
              _metadata = title.enrichment ?? _metadata;
            });
          }
        } catch (e) {
          if (mounted && gen == _generation) setState(() => _error = _message(e));
        }
      }(),
      () async {
        try {
          final watch = await widget.client.showWatch(_title.media.id);
          if (mounted && gen == _generation) setState(() => _watch = watch);
        } catch (e) {
          if (mounted && gen == _generation) setState(() => _error = _message(e));
        }
      }(),
    ]);
    if (!mounted || gen != _generation) return;
    setState(() => _loading = false);
    if (_focusOnLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focusOnLoad && requestFocus()) _focusOnLoad = false;
      });
    }
  }

  String _message(Object e) => e is TedFailure ? e.message : const TedFailure('unavailable').message;
  Future<void> _work(Future<void> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) await reload();
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      controller: _scroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            // Leave room for the actions and full Seasons shelf on opening.
            height: (box.maxHeight - 466.0).clamp(280.0, 600.0),
            child: TedHomeBanner(
              client: widget.client,
              entries: [_title],
              refreshEpoch: 0,
              catalogPreview: true,
              debounceEnrichment: false,
              loadDetails: false,
              showReleaseDate: true,
              releaseDate: _metadata?.premiereDate,
              contentHorizontalInset: widget.horizontalInset,
              onPlay: (_) async {},
              onOpen: (_) async {},
              onBack: widget.onSidebar,
              onMetadata: (_, snapshot) {
                if (mounted && snapshot.type == 'Series') setState(() => _metadata = snapshot);
              },
            ),
          ),
          if (_loading || _working) const LinearProgressIndicator(),
          TedFocusRegion(
            key: _actions,
            scroll: false,
            onUp: widget.onHeader,
            onDown: () => _focusSeasons(),
            onLeft: widget.onSidebar,
            onBack: widget.onClose,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset, vertical: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _selectable(
                    TedDownloadButton(
                      downloads: widget.downloads,
                      media: _title.media,
                      label: 'Download show',
                      onPressed: _working || _loading || widget.onDownload == null || _title.seasons.isEmpty
                          ? null
                          : () => _work(() => widget.onDownload!(_title)),
                    ),
                  ),
                  _selectable(
                    OutlinedButton.icon(
                      onPressed: _working || _loading || _watch == null || _watch!.count == 0
                          ? null
                          : () => _work(
                              () => widget.client.setShowWatched(_title.media.id, _watch!.version, !_title.played),
                            ),
                      icon: Icon(_title.played ? Icons.check_circle : Icons.check_circle_outline),
                      label: Text(_title.played ? 'Mark show unwatched' : 'Mark show watched'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset),
              child: Row(
                children: [
                  Expanded(child: Text(_error!)),
                  TextButton(onPressed: _working || _loading ? null : reload, child: const Text('Retry')),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: (widget.horizontalInset - 3).clamp(0, double.infinity)),
            child: HubSection(
              key: _seasons,
              showUnviewedCount: true,
              hub: MediaHub(
                id: 'seasons:${_title.media.id}',
                title: 'Seasons',
                type: 'season',
                serverId: TedPresentation(widget.client).scope,
                items: [
                  for (final season
                      in ([..._title.seasons]..sort(
                        (a, b) => a == 0
                            ? (b == 0 ? 0 : 1)
                            : b == 0
                            ? -1
                            : a.compareTo(b),
                      )))
                    MediaItem.ted(
                      id: 'season/${_title.media.id}/$season',
                      serverId: TedPresentation(widget.client).scope,
                      serverName: 'TED',
                      kind: MediaKind.season,
                      title: season == 0 ? 'Specials' : 'Season $season',
                      index: season,
                      leafCount: _watch?.seasonCounts[season]?.$1,
                      viewedLeafCount: _watch?.seasonCounts[season]?.$2,
                      raw: {'joint_watches': _watch?.jointCounts[season]?.map((w) => w.toJson()).toList() ?? []},
                      thumbPath: _title.poster,
                    ),
                ],
              ),
              focusMemory: _memory,
              icon: Icons.video_library_outlined,
              inset: true,
              cardSizing: HubCardSizing.grid,
              maxCardWidth: 180,
              onItemTap: (item) => widget.onSeason(item.index!),
              onItemLongPress: (_) {},
              onFocusedItemChanged: (_) {
                _lane = 'seasons';
                _revealSeasons();
              },
              onNavigateToSidebar: widget.onSidebar,
              onBack: widget.onClose,
              onVerticalNavigation: (up) {
                if (up) {
                  _actions.currentState?.requestFocus();
                } else {
                  _cast.currentState?.requestFocus();
                }
                return true;
              },
              autoScroll: false,
              artworkBuilder: (context, item, width, height) => _SeasonPoster(
                artwork: _artwork,
                season: item.index!,
                width: width,
                height: height,
                fallback: _title.poster,
              ),
            ),
          ),
          TedCastRow(
            key: _cast,
            client: widget.client,
            people: _metadata?.people ?? const [],
            loading: _loading || _metadata?.pending == true,
            horizontalInset: widget.horizontalInset,
            onUp: () => _focusSeasons(),
            onLeft: widget.onSidebar,
            onBack: widget.onClose,
            onFocusChanged: (value) {
              if (value) _lane = 'cast';
            },
            onPerson: (person) => widget.onPerson(person, _title, _metadata),
          ),
          const SizedBox(height: 24),
        ],
      ),
    ),
  );
}

class TedSeasonDetail extends StatefulWidget {
  final TedClient client;
  final TedTitle show;
  final int season;
  final TedMediaIdentity? initialEpisode;
  final double horizontalInset;
  final VoidCallback onClose, onSidebar, onHeader;
  final ValueChanged<TedTitle> onEpisode;
  final Future<void> Function(TedTitle, int)? onDownload;
  final TedDownloads? downloads;
  final void Function(TedMetadataPerson, TedTitle, TedMetadataSnapshot?)? onPerson;
  const TedSeasonDetail({
    super.key,
    required this.client,
    required this.show,
    required this.season,
    this.initialEpisode,
    required this.horizontalInset,
    required this.onClose,
    required this.onSidebar,
    required this.onHeader,
    required this.onEpisode,
    this.onDownload,
    this.downloads,
    this.onPerson,
  });
  @override
  State<TedSeasonDetail> createState() => TedSeasonDetailState();
}

class TedSeasonDetailState extends State<TedSeasonDetail> {
  final _scroll = ScrollController();
  final _actions = GlobalKey<TedFocusRegionState>();
  final _episodes = GlobalKey<HubSectionState>();
  final _retry = GlobalKey<TedFocusRegionState>();
  final _cast = GlobalKey<TedCastRowState>();
  final _memory = HubFocusMemory();
  late final _artwork = _SeasonArtwork(widget.client, widget.show);
  late final _thumbnails = TedPersonalArtwork(widget.client, loadEpisodeDetails: false);
  late TedTitle _show = widget.show;
  List<TedTitle> _titles = [];
  TedMetadataSnapshot? _seasonMetadata;
  TedSeriesWatch? _watch;
  int? _after;
  int _generation = 0;
  bool _loading = false, _more = false, _working = false, _focusOnLoad = true;
  bool _episodesRevealPending = false;
  String _lane = 'episodes';
  late bool _initialSelectionPending = widget.initialEpisode != null;
  String? _error;
  bool requestFocus() {
    if (_lane == 'cast' && (_cast.currentState?.requestFocus() ?? false)) return true;
    if (_lane == 'actions' && (_actions.currentState?.requestFocus() ?? false)) return true;
    return _focusEpisodes() ||
        (_actions.currentState?.requestFocus() ?? false) ||
        (_retry.currentState?.requestFocus() ?? false);
  }

  bool _focusEpisodes() {
    if (_titles.isNotEmpty && _episodes.currentState != null) {
      final selected = _initialSelectionPending ? _titles.indexWhere((t) => t.media == widget.initialEpisode) : -1;
      if (selected >= 0) {
        _episodes.currentState!.requestFocusAt(selected);
      } else {
        _episodes.currentState!.requestFocusFromMemory();
      }
      _initialSelectionPending = false;
      return true;
    }
    return false;
  }

  void _revealEpisodes() {
    if (_episodesRevealPending) return;
    _episodesRevealPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _episodesRevealPending = false;
      if (mounted) _revealDetailShelf(_episodes.currentState);
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
    _artwork.dispose();
    _thumbnails.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _watch = null;
      _error = null;
    });
    try {
      await Future.wait([
        _loadEpisodes(gen),
        () async {
          try {
            final watch = await widget.client.seasonWatch(_show.media.id, widget.season);
            if (mounted && gen == _generation) setState(() => _watch = watch);
          } catch (e) {
            if (mounted && gen == _generation) setState(() => _error = _message(e));
          }
        }(),
      ]);
    } finally {
      if (mounted && gen == _generation) {
        setState(() => _loading = false);
        if (_focusOnLoad) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _focusOnLoad && requestFocus()) _focusOnLoad = false;
          });
        }
      }
    }
  }

  Future<void> _loadEpisodes(int gen) async {
    try {
      // Returning from a deep episode must retain every realized page, so its
      // remembered card remains present while watch badges refresh.
      _more = false;
      final retainedCount = _titles.length;
      final titles = <TedTitle>[];
      TedMetadataSnapshot? metadata;
      int? after;
      do {
        final page = await widget.client.episodes(_show.media.id, widget.season, after: after);
        if (!mounted || gen != _generation) return;
        if (page.nextAfter != null && after != null && page.nextAfter! <= after) {
          throw const TedFailure('invalid_response');
        }
        titles.addAll(page.titles);
        metadata ??= page.enrichment;
        after = page.nextAfter;
        if (titles.length > 10000) throw const TedFailure('invalid_response');
      } while (after != null &&
          (titles.length < retainedCount ||
              _initialSelectionPending && !titles.any((t) => t.media == widget.initialEpisode)));
      if (!mounted || gen != _generation) return;
      setState(() {
        _titles = titles;
        _after = after;
        _seasonMetadata = metadata;
      });
      unawaited(_refreshSeason(gen));
    } catch (e) {
      if (mounted && gen == _generation) setState(() => _error = _message(e));
    }
  }

  Future<void> _work(Future<void> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) await reload();
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) {
        setState(() => _working = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _lane == 'actions' && ModalRoute.of(context)?.isCurrent != false) requestFocus();
        });
      }
    }
  }

  Widget _selectable(Widget child) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (value) {
      if (value) {
        _lane = 'actions';
        _top();
      }
    },
    child: child,
  );

  Future<void> _refreshSeason(int gen) async {
    try {
      final art = await _artwork.load(widget.season);
      if (!mounted || gen != _generation) return;
      setState(() => _seasonMetadata = art.snapshot);
      // Season enrichment seeds all child thumbnail references without full
      // episode descriptions. Reload only the existing paged summaries.
      final pages = <TedTitle>[];
      final initialCount = _titles.length;
      final initialAfter = _after;
      int? after;
      do {
        final page = await widget.client.episodes(_show.media.id, widget.season, after: after);
        if (!mounted || gen != _generation) return;
        pages.addAll(page.titles);
        after = page.nextAfter;
      } while (after != null && pages.length < initialCount);
      setState(() {
        final updates = {for (final t in pages) t.media: t};
        _titles = _titles.map((t) => updates[t.media] ?? t).toList();
        if (_after == initialAfter && !_more) _after = after;
      });
    } catch (_) {
      /* Existing summaries/artwork remain usable during provider failure. */
    }
  }

  String _message(Object e) => e is TedFailure ? e.message : const TedFailure('unavailable').message;
  Future<void> _loadMore() async {
    if (_more || _after == null || _loading) return;
    final gen = _generation, after = _after;
    setState(() => _more = true);
    try {
      final page = await widget.client.episodes(_show.media.id, widget.season, after: after);
      if (!mounted || gen != _generation) return;
      if (page.nextAfter != null && page.nextAfter! <= after!) throw const TedFailure('invalid_response');
      setState(() {
        _titles = {
          for (final t in [..._titles, ...page.titles]) t.media: t,
        }.values.toList();
        _after = page.nextAfter;
      });
    } catch (e) {
      if (mounted && gen == _generation) setState(() => _error = _message(e));
    } finally {
      if (mounted && gen == _generation) setState(() => _more = false);
    }
  }

  void _top() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted &&
        InputModeTracker.currentMode == InputMode.keyboard &&
        _scroll.hasClients &&
        ModalRoute.of(context)?.isCurrent != false &&
        _scroll.offset > 1) {
      unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic));
    }
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      controller: _scroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: (box.maxHeight * .66).clamp(300.0, 740.0),
            child: TedHomeBanner(
              client: widget.client,
              entries: [_show],
              refreshEpoch: 0,
              catalogPreview: true,
              debounceEnrichment: false,
              loadDetails: _show.enrichment == null,
              onMetadata: (media, snapshot) {
                if (mounted &&
                    media == _show.media &&
                    snapshot.type == 'Series' &&
                    !identical(snapshot, _show.enrichment)) {
                  setState(() => _show = _show.withEnrichment(snapshot));
                }
              },
              contentHorizontalInset: widget.horizontalInset,
              leadingArtwork: _SeasonPoster(artwork: _artwork, season: widget.season, fallback: _show.poster),
              showReleaseDate: true,
              releaseDate:
                  _seasonMetadata?.premiereDate ??
                  _titles.map((v) => v.enrichment?.premiereDate ?? v.releaseDate).whereType<DateTime>().firstOrNull,
              detailHeading: widget.season == 0 ? 'Specials' : 'Season ${widget.season}',
              descriptionOverride: _seasonMetadata?.overview.isNotEmpty == true
                  ? _seasonMetadata!.overview
                  : _show.description.isEmpty
                  ? null
                  : _show.description,
              onPlay: (_) async {},
              onOpen: (_) async {},
              onBack: widget.onSidebar,
            ),
          ),
          if (_loading || _more || _working) const LinearProgressIndicator(),
          TedFocusRegion(
            key: _actions,
            scroll: false,
            onUp: widget.onHeader,
            onDown: () => _focusEpisodes(),
            onLeft: widget.onSidebar,
            onBack: widget.onClose,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset, vertical: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _selectable(
                    TedDownloadButton(
                      downloads: widget.downloads,
                      media: _show.media,
                      season: widget.season,
                      label: 'Download season',
                      onPressed: _working || _loading || widget.onDownload == null || _titles.isEmpty
                          ? null
                          : () => _work(() => widget.onDownload!(_show, widget.season)),
                    ),
                  ),
                  _selectable(
                    OutlinedButton.icon(
                      onPressed: _working || _loading || _watch == null || _watch!.count == 0
                          ? null
                          : () => _work(
                              () => widget.client.setSeasonWatched(
                                _show.media.id,
                                widget.season,
                                _watch!.version,
                                !_watch!.fullyWatched,
                              ),
                            ),
                      icon: Icon(_watch?.fullyWatched == true ? Icons.check_circle : Icons.check_circle_outline),
                      label: Text(_watch?.fullyWatched == true ? 'Mark season unwatched' : 'Mark season watched'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null)
            TedFocusRegion(
              key: _retry,
              onBack: widget.onClose,
              onLeft: widget.onSidebar,
              onUp: widget.onHeader,
              onDown: () => _focusEpisodes(),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset),
                child: Row(
                  children: [
                    Expanded(child: Text(_error!)),
                    TextButton(onPressed: _loading || _working ? null : reload, child: const Text('Retry')),
                  ],
                ),
              ),
            ),
          if (_titles.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: (widget.horizontalInset - 3).clamp(0, double.infinity)),
              child: HubSection(
                key: _episodes,
                hub: MediaHub(
                  id: 'episodes:${_show.media.id}:${widget.season}',
                  title: 'Episodes',
                  type: 'episode',
                  serverId: TedPresentation(widget.client).scope,
                  items: _titles.map(TedPresentation(widget.client).item).toList(),
                ),
                focusMemory: _memory,
                icon: Icons.movie_outlined,
                inset: true,
                showHeader: false,
                autoScroll: false,
                maxCardWidth: 300,
                episodePosterModeOverride: EpisodePosterMode.episodeThumbnail,
                onItemTap: (item) => widget.onEpisode(_titles.firstWhere((t) => 'episode/${t.media.id}' == item.id)),
                onItemLongPress: (_) {},
                onFocusedItemChanged: (_) {
                  _lane = 'episodes';
                  _revealEpisodes();
                },
                onNearEnd: () => unawaited(_loadMore()),
                onBack: widget.onClose,
                onNavigateToSidebar: widget.onSidebar,
                onVerticalNavigation: (up) {
                  if (up) {
                    if (!(_actions.currentState?.requestFocus() ?? false)) widget.onHeader();
                  } else {
                    _cast.currentState?.requestFocus();
                  }
                  return true;
                },
                artworkBuilder: (context, item, width, height) => TedPersonalThumbnail(
                  artwork: _thumbnails,
                  protectSpoilers: false,
                  title: _titles.firstWhere((t) => 'episode/${t.media.id}' == item.id),
                  width: width,
                  height: height,
                ),
                captionBuilder: (context, item) {
                  final title = _titles.firstWhere((t) => 'episode/${t.media.id}' == item.id);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.enrichment?.name.isNotEmpty == true ? title.enrichment!.name : title.episodeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, height: 1.1),
                      ),
                      Text(
                        'Season ${title.season} Episode ${title.episode}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11, height: 1.1),
                      ),
                      Text(
                        tedReleaseDate(title.enrichment?.premiereDate ?? title.releaseDate),
                        maxLines: 1,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11, height: 1.1),
                      ),
                    ],
                  );
                },
                captionExtraHeight: 14,
              ),
            ),
          if (!_loading && _titles.isEmpty && _error == null)
            const Padding(padding: EdgeInsets.all(24), child: Text('No episodes in this season.')),
          TedCastRow(
            key: _cast,
            client: widget.client,
            people: _show.enrichment?.people ?? const [],
            loading: _show.enrichment?.pending == true,
            horizontalInset: widget.horizontalInset,
            onUp: () {
              _lane = 'episodes';
              _focusEpisodes();
            },
            onLeft: widget.onSidebar,
            onBack: widget.onClose,
            onFocusChanged: (focused) {
              if (focused) _lane = 'cast';
            },
            onPerson: widget.onPerson == null ? null : (person) => widget.onPerson!(person, _show, _show.enrichment),
          ),
          const SizedBox(height: 24),
        ],
      ),
    ),
  );
}

class _SeasonArt {
  final TedMetadataSnapshot? snapshot;
  final Uint8List? bytes;
  const _SeasonArt(this.snapshot, this.bytes);
}

/// Only realized season cards request their own poster metadata. Five bounded
/// workflows, with scoped private bytes, never enqueue person biographies.
class _SeasonArtwork {
  final TedClient client;
  final TedTitle show;
  final (Uri?, int?) _scope;
  final _cache = <int, _SeasonArt>{};
  final _pending = <int, Completer<_SeasonArt>>{};
  final _queue = Queue<int>();
  int _active = 0, _bytes = 0;
  bool _disposed = false;
  _SeasonArtwork(this.client, this.show) : _scope = (client.auth.server, client.auth.userId);
  bool get valid => !_disposed && _scope == (client.auth.server, client.auth.userId);
  Future<_SeasonArt> load(int season) {
    if (!valid) return Future.value(const _SeasonArt(null, null));
    if (_cache.containsKey(season)) return Future.value(_cache[season]);
    if (_pending.containsKey(season)) return _pending[season]!.future;
    final done = Completer<_SeasonArt>();
    _pending[season] = done;
    _queue.add(season);
    _pump();
    return done.future;
  }

  void _pump() {
    while (valid && _active < 5 && _queue.isNotEmpty) {
      _active++;
      unawaited(_run(_queue.removeFirst()));
    }
  }

  Future<void> _run(int season) async {
    TedMetadataSnapshot? snapshot;
    Uint8List? bytes;
    try {
      var current = await client.season(show.media.id, season);
      snapshot = current;
      for (var i = 0; valid && current.pending && i < 20; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (valid) {
          current = await client.metadata(current.id);
          snapshot = current;
        }
      }
      final asset = current.images.where((v) => v.type == 'Primary').firstOrNull;
      if (asset != null) {
        for (var i = 0; valid && i < 12; i++) {
          bytes = await client.metadataImage(asset.id);
          if (bytes != null) break;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    } catch (_) {
      /* Keep the show's poster when this provider has no season art. */
    } finally {
      final art = _SeasonArt(snapshot, bytes);
      if (valid) {
        _cache[season] = art;
        _bytes += bytes?.length ?? 0;
        while (_cache.length > 64 || _bytes > 20 * 1024 * 1024) {
          _bytes -= _cache.remove(_cache.keys.first)?.bytes?.length ?? 0;
        }
      }
      _pending.remove(season)?.complete(valid ? art : const _SeasonArt(null, null));
      _active--;
      _pump();
    }
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
    _queue.clear();
    for (final done in _pending.values) {
      if (!done.isCompleted) done.complete(const _SeasonArt(null, null));
    }
    _pending.clear();
  }
}

class _SeasonPoster extends StatefulWidget {
  final _SeasonArtwork artwork;
  final int season;
  final String fallback;
  final double? width, height;
  const _SeasonPoster({required this.artwork, required this.season, required this.fallback, this.width, this.height});
  @override
  State<_SeasonPoster> createState() => _SeasonPosterState();
}

class _SeasonPosterState extends State<_SeasonPoster> {
  late Future<_SeasonArt> _future = widget.artwork.load(widget.season);
  @override
  void didUpdateWidget(_SeasonPoster old) {
    super.didUpdateWidget(old);
    if (old.artwork != widget.artwork || old.season != widget.season) _future = widget.artwork.load(widget.season);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_SeasonArt>(
    future: _future,
    builder: (context, state) {
      final fallback = widget.fallback.isEmpty
          ? const Center(child: Icon(Icons.video_library_outlined, size: 40))
          : Image.network(
              widget.fallback,
              width: widget.width,
              height: widget.height,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Center(child: Icon(Icons.video_library_outlined, size: 40)),
            );
      return state.data?.bytes == null
          ? fallback
          : Image.memory(
              state.data!.bytes!,
              width: widget.width,
              height: widget.height,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            );
    },
  );
}
