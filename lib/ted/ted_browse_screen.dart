import 'ted_back_scope.dart';
import 'dart:async';
import '../models/teddy_section.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/dpad_navigator.dart';
import '../focus/key_event_utils.dart';
import '../focus/focusable_wrapper.dart';
import '../focus/focusable_text_field.dart';
import '../focus/input_mode_tracker.dart';
import '../focus/focus_theme.dart';
import '../focus/locked_hub_controller.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../widgets/hub_section.dart';
import '../widgets/media_card.dart';
import '../widgets/media_grid_delegate.dart';
import '../widgets/settings_builder.dart';
import '../widgets/navigation_rail_item.dart';
import '../widgets/clickable_cursor.dart';
import '../utils/desktop_window_padding.dart';
import '../utils/layout_constants.dart';
import '../utils/platform_detector.dart';
import '../services/settings_service.dart' show SettingsService, ViewMode, EpisodePosterMode, GridSpacingMetrics;
import '../widgets/cycling_media_backdrop.dart';
import '../widgets/app_bar_back_button.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../screens/settings/licenses_screen.dart';
import 'ted_catalog_screen.dart' show TedPlay;
import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_presentation.dart';
import 'ted_app_bar.dart';
import 'ted_home_banner.dart';
import 'ted_home_selection.dart';
import 'ted_personal_thumbnail.dart';
import 'ted_cached_poster.dart';
import 'ted_browse_header.dart';
import 'ted_focus_region.dart';
import 'ted_focus_recovery.dart';
import 'ted_catalog_filters.dart';
import 'ted_movie_detail.dart';
import 'ted_person_detail.dart';
import 'ted_series_detail.dart';
import 'ted_metadata_models.dart';
import 'ted_downloads.dart';
import 'ted_downloads_screen.dart';
import 'teddy_settings_screen.dart';

/// Plezy's shared rails/cards and input navigation, populated by TED's APIs.
/// The surface owns paging/navigation only; TED owns sources and watch state.
class TedBrowseScreen extends StatefulWidget {
  final TedClient client;
  final TedDownloads? downloads;
  final TedPlay onPlay;
  final TedPlay? onDownload;
  final TedPlay? onDownloadSeries;
  final Future<void> Function(TedTitle, int)? onDownloadSeason;
  final TedSelectedPlay? onPlaySelection;
  final TedSelectedDownload? onDownloadSelection;
  final int refreshEpoch;
  final String displayName;
  final Uint8List? profilePicture;
  final VoidCallback? onReload;
  final VoidCallback? onSettings, onSignOut, onSwitchProfile, onChangeServer;
  final VoidCallback? onLayoutRestart;
  const TedBrowseScreen({
    super.key,
    required this.client,
    this.downloads,
    required this.onPlay,
    this.onDownload,
    this.onDownloadSeries,
    this.onDownloadSeason,
    this.onPlaySelection,
    this.onDownloadSelection,
    this.refreshEpoch = 0,
    this.displayName = '',
    this.profilePicture,
    this.onReload,
    this.onSettings,
    this.onLayoutRestart,
    this.onSignOut,
    this.onSwitchProfile,
    this.onChangeServer,
  });
  @override
  State<TedBrowseScreen> createState() => TedBrowseScreenState();
}

sealed class _DetailPage {
  final scope = FocusScopeNode(debugLabel: 'ted_detail_page', traversalEdgeBehavior: TraversalEdgeBehavior.parentScope);
  // Synthetic episode ancestors are mounted only when Back first visits them.
  bool visited = true;
  bool requestFocus();
  Future<void> reload();
}

class _MoviePage extends _DetailPage {
  final TedTitle title;
  final key = GlobalKey<TedMovieDetailState>();
  _MoviePage(this.title);
  @override
  bool requestFocus() => key.currentState?.requestFocus() ?? false;
  @override
  Future<void> reload() async => key.currentState?.reload();
}

class _SeriesPage extends _DetailPage {
  final TedTitle title;
  final key = GlobalKey<TedSeriesDetailState>();
  _SeriesPage(this.title);
  @override
  bool requestFocus() => key.currentState?.requestFocus() ?? false;
  @override
  Future<void> reload() async => key.currentState?.reload();
}

class _SeasonPage extends _DetailPage {
  final TedTitle title;
  final int season;
  final TedMediaIdentity? initialEpisode;
  final key = GlobalKey<TedSeasonDetailState>();
  _SeasonPage(this.title, this.season, {this.initialEpisode});
  @override
  bool requestFocus() => key.currentState?.requestFocus() ?? false;
  @override
  Future<void> reload() async => key.currentState?.reload();
}

class _PersonPage extends _DetailPage {
  final TedMetadataPerson person;
  final TedTitle origin;
  final TedMetadataSnapshot? metadata;
  final key = GlobalKey<TedPersonDetailState>();
  _PersonPage(this.person, this.origin, this.metadata);
  @override
  bool requestFocus() => key.currentState?.requestFocus() ?? false;
  @override
  Future<void> reload() async => key.currentState?.reload();
}

class _SettingsPage extends _DetailPage {
  final key = GlobalKey<TeddySettingsScreenState>();
  @override
  bool requestFocus() => key.currentState?.requestFocus() ?? false;
  @override
  Future<void> reload() async {}
}

class _LicensesPage extends _DetailPage {
  final MergedLicenseEntry? license;
  final key = GlobalKey<FocusedScrollScaffoldState>();
  _LicensesPage([this.license]);
  @override
  bool requestFocus() => key.currentState?.requestFocus() ?? false;
  @override
  Future<void> reload() async {}
}

class TedBrowseScreenState extends State<TedBrowseScreen> {
  static final _sections = TeddySection.values.map((value) => value.id).toList();
  static final _icons = TeddySection.values.map((value) => value.icon).toList();
  final _downloadsKey = GlobalKey<TedDownloadsScreenState>();
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'ted_search');
  final _searchTypeFocus = FocusNode(debugLabel: 'ted_search_type');
  final _searchButtonFocus = FocusNode(debugLabel: 'ted_search_button');
  final _browseFocus = FocusNode(debugLabel: 'ted_browse', skipTraversal: true);
  final _focusMemory = HubFocusMemory();
  var _catalogFocusMemory = HubFocusMemory();
  final _sidebarFocus = FocusNode(debugLabel: 'ted_sidebar', skipTraversal: true);
  bool _sidebarHovered = false, _sidebarMenuOpen = false;
  final _navFocus = List.generate(_sections.length, (_) => FocusNode());
  final _bannerKey = GlobalKey<TedHomeBannerState>();
  final _details = <_DetailPage>[];
  final _contentScope = FocusScopeNode(
    debugLabel: 'ted_browse_content',
    traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
  );
  String? _movieReturnStop;
  final _controlsKey = GlobalKey<TedFocusRegionState>();
  final _detailBackKey = GlobalKey<TedFocusRegionState>();
  final _bottomKey = GlobalKey<TedFocusRegionState>();
  final _laneKeys = <String, GlobalKey<TedFocusRegionState>>{};
  final _hubKeys = <String, GlobalKey<HubSectionState>>{};
  final _stops = <(String, bool Function())>[];
  int _sidebarOrigin = 1;
  String? _sidebarReturnStop;
  FocusNode? _activationOrigin;
  bool _wide = true;
  bool _continueRevealPending = false;
  String _section = 'home', _query = '', _catalog = 'popular';
  String _watchFilter = 'all', _genre = '';
  String _searchKind = 'movie';
  bool _mappedOnly = false;
  int _catalogEpoch = 0;
  final _catalogPreview = ValueNotifier<TedTitle?>(null);
  TedTitle? get _catalogSelection => _catalogPreview.value;
  set _catalogSelection(TedTitle? title) => _catalogPreview.value = title;
  bool _catalogPageScheduled = false;
  List<TedTitle> _titles = [];
  List<TedHomeRow> _rows = [];
  List<TedCatalogIssue> _issues = [];
  String? _after, _error;
  int? _skip;
  int _generation = 0;
  bool _busy = true;
  bool _failedMore = false;
  late TedPersonalArtwork _personalArtwork;
  late MediaCardArtworkBuilder _personalBuilder;
  TedPresentation get _presentation => TedPresentation(widget.client);
  @override
  void initState() {
    super.initState();
    _section = SettingsService.instance.read(SettingsService.teddyStartupSection).id;
    _sidebarOrigin = _sections.indexOf(_section);
    HardwareKeyboard.instance.addHandler(_backWithoutFocus);
    _personalArtwork = TedPersonalArtwork(widget.client);
    _personalBuilder = (context, item, width, height) => _personalImage(context, item, width, height);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(TedBrowseScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client || !_personalArtwork.valid || oldWidget.refreshEpoch != widget.refreshEpoch) {
      _resetPersonalArtwork();
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_backWithoutFocus);
    _catalogPreview.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _searchTypeFocus.dispose();
    _searchButtonFocus.dispose();
    _browseFocus.dispose();
    _sidebarFocus.dispose();
    _contentScope.dispose();
    for (final page in _details) {
      page.scope.dispose();
    }
    _personalArtwork.dispose();
    for (final node in _navFocus) {
      node.dispose();
    }
    super.dispose();
  }

  bool _personal(String section) => ['continue-watching', 'new-releases', 'next-up'].contains(section);

  Widget? _cachedPoster(BuildContext context, MediaItem item, double? width, double? height) {
    final title = [
      ..._titles,
      for (final row in _rows) ...row.titles,
    ].where((title) => _presentation.item(title).id == item.id).firstOrNull;
    final image = title?.enrichment?.images
        .where((a) => a.type == 'Primary' && a.index == 0 && a.userModified && a.tag.isNotEmpty)
        .firstOrNull;
    if (title == null || image == null) return null;
    return TedCachedPoster(client: widget.client, asset: image, fallback: title.poster, width: width, height: height);
  }

  void _resetPersonalArtwork() {
    _personalArtwork.dispose();
    _personalArtwork = TedPersonalArtwork(widget.client);
    // A new builder also invalidates Plezy's memoized cards, so they receive
    // the new owner instead of retaining a disposed loader or stale image.
    _personalBuilder = (context, item, width, height) => _personalImage(context, item, width, height);
  }

  Future<void> _reload() async {
    widget.onReload?.call();
    if (_section == 'downloads' && _details.isEmpty) {
      await _downloadsKey.currentState?.reload();
      return;
    }
    if (_details.isNotEmpty) {
      await _details.last.reload();
      return;
    }
    _resetPersonalArtwork();
    await _load();
  }

  Widget? _personalImage(BuildContext context, MediaItem item, double? width, double? height) {
    if (item.kind != MediaKind.episode && item.kind != MediaKind.movie) return null;
    final title = [
      ..._titles,
      for (final row in _rows) ...row.titles,
    ].where((title) => _presentation.item(title).id == item.id).firstOrNull;
    if (title == null) return null;
    return TedPersonalThumbnail(
      artwork: _personalArtwork,
      title: title,
      width: width,
      height: height,
      protectSpoilers: false,
    );
  }

  Future<void> _load({bool more = false, String? returnStop}) async {
    if (more && (_busy || (_after == null && _skip == null))) return;
    final restoreFocus = InputModeTracker.currentMode == InputMode.keyboard && _browseFocus.hasFocus;
    final fromControls = _controlsKey.currentState?.hasFocus ?? false;
    final generation = ++_generation;
    final account = widget.client.auth.userId;
    final section = _section, query = _query;
    final previousHomeRows = {for (final row in _rows) row.id: row};
    List<TedHomeRow> retainHomeRows(List<TedHomeRow> rows) => [
      for (final row in rows)
        if ((row.loading || row.unavailable) && previousHomeRows.containsKey(row.id))
          TedHomeRow(row.id, previousHomeRows[row.id]!.titles, row.unavailable, row.issues, loading: row.loading)
        else
          row,
    ];
    var emptyPage = false;
    setState(() {
      _busy = true;
      _error = null;
      _failedMore = false;
    });
    try {
      List<TedTitle> titles = [];
      List<TedHomeRow> rows = [];
      List<TedCatalogIssue> issues = [];
      String? after;
      int? skip;
      switch (section) {
        case 'downloads':
          break;
        case 'home':
          rows = retainHomeRows(
            await widget.client.home(
              onUpdate: (partial) {
                if (!mounted || generation != _generation || account != widget.client.auth.userId) return;
                setState(() => _rows = retainHomeRows(partial));
                _scheduleActivatedFocus();
              },
            ),
          );
        case 'continue-watching' || 'new-releases' || 'next-up':
          final page = await widget.client.personal(section, after: more ? _after : null);
          titles = page.titles;
          after = page.nextAfter;
          issues = page.issues;
        case 'search':
          final page = await widget.client.browse(_searchKind, search: query, skip: more ? _skip ?? 0 : 0);
          titles = page.titles;
          skip = page.nextSkip;
        default:
          final page = await widget.client.browse(
            section,
            skip: more ? _skip ?? 0 : 0,
            after: more ? _after : null,
            catalog: _catalog,
            genre: _genre,
            mapped: _mappedOnly,
            watched: _watchFilter,
          );
          titles = page.titles;
          skip = page.nextSkip;
          after = page.nextAfter;
      }
      emptyPage = titles.isEmpty;
      if (!mounted || generation != _generation || account != widget.client.auth.userId) return;
      setState(() {
        _titles = more
            ? {
                for (final title in [..._titles, ...titles]) title.media: title,
              }.values.toList()
            : titles;
        _rows = rows;
        _issues = issues;
        _after = after;
        _skip = skip;
        if (_catalogView) {
          _catalogSelection =
              _titles.where((t) => t.media == _catalogSelection?.media).firstOrNull ?? _titles.firstOrNull;
        }
      });
    } on TedFailure catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error.message;
          _failedMore = more;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = const TedFailure('unavailable').message;
          _failedMore = more;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
        _scheduleActivatedFocus();
        if (more && emptyPage && _error == null) _moreCatalog();
        if (PlatformDetector.isTV() &&
            _catalogView &&
            _error == null &&
            _titles.isEmpty &&
            (_skip != null || _after != null)) {
          // Genre intersections can yield an empty intermediate year page.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && generation == _generation) unawaited(_load(more: true));
          });
        }
        if (restoreFocus) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || generation != _generation || ModalRoute.of(context)?.isCurrent == false) return;
            // A removed/disabled control must not strand focus on a bare
            // scope. A user who moved elsewhere while waiting keeps focus.
            if (!_browseFocus.hasFocus) {
              if (fromControls) {
                _focusControls();
              } else {
                final stop = _stops.where((s) => s.$1 == returnStop).firstOrNull;
                if (stop == null || !stop.$2()) _focusMain();
              }
            }
          });
        }
      }
    }
  }

  void _activateSection(String section) {
    final origin = FocusManager.instance.primaryFocus;
    final keyboard = InputModeTracker.currentMode == InputMode.keyboard;
    _activationOrigin = null;
    _select(section);
    if (keyboard) {
      _activationOrigin = origin;
      _scheduleActivatedFocus();
    }
  }

  void _scheduleActivatedFocus() {
    final origin = _activationOrigin;
    if (origin == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_activationOrigin, origin)) return;
      if (!origin.hasFocus ||
          InputModeTracker.currentMode != InputMode.keyboard ||
          ModalRoute.of(context)?.isCurrent == false ||
          _details.isNotEmpty) {
        _activationOrigin = null;
        return;
      }
      // Clear before requesting focus: a delayed response must not steal it back.
      _activationOrigin = null;
      if (_section == 'search' && _searchFocus.context != null) {
        _searchFocus.requestFocus();
        return;
      }
      if (_section == 'downloads') {
        if (!(_downloadsKey.currentState?.requestFocus(first: true) ?? false)) _activationOrigin = origin;
        return;
      }
      if (_section == 'home') {
        final row = _rows.where((row) => row.titles.isNotEmpty).firstOrNull;
        final shelf = row == null ? null : _hubKeys[row.id]?.currentState;
        if (shelf != null) {
          shelf.requestFocusAt(0);
          return;
        }
      } else if (_catalogView && _titles.isNotEmpty) {
        if (PlatformDetector.isTV()) {
          final shelf = _hubKeys['catalog:$_section:$_catalogEpoch']?.currentState;
          if (shelf != null) {
            shelf.requestFocusAt(0);
            return;
          }
        } else if (_laneKeys['grid:$_section']?.currentState?.requestFocus(first: true) ?? false) {
          return;
        }
      }
      if (_busy) {
        _activationOrigin = origin;
        return;
      }
      // Empty/error pages still offer their filters or retry control.
      for (final stop in _stops) {
        if (stop.$2()) return;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _select(String section) {
    if (_section == section && _details.isEmpty) return;
    final closed = _details.toList();
    setState(() {
      _details.clear();
      _section = section;
      _sidebarOrigin = _sections.indexOf(section);
      _sidebarReturnStop = null;
      _titles = [];
      _rows = [];
      _issues = [];
      _after = null;
      _skip = null;
      _catalogSelection = null;
      _catalogEpoch++;
      _catalogFocusMemory = HubFocusMemory();
    });
    // Detach the old pages before disposing their scopes. Settings can still
    // own focus when a destination is clicked, unlike an Enter from the rail.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final page in closed) {
        page.scope.dispose();
      }
    });
    unawaited(_load());
  }

  bool get _catalogView => _section == 'movie' || _section == 'series' || _section == 'search';
  String get _catalogKind => _section == 'search' ? _searchKind : _section;

  void _changeCatalogFilters(VoidCallback change) {
    setState(() {
      change();
      _titles = [];
      _catalogSelection = null;
      _after = null;
      _skip = null;
      _catalogEpoch++;
      _catalogFocusMemory = HubFocusMemory();
    });
    unawaited(_load());
  }

  void _catalogFocused(MediaItem item) {
    // HubSection can report selection during a focus request/build. Commit on
    // the next frame and verify both section and shelf generation first.
    final epoch = _catalogEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _catalogEpoch || !_catalogView) return;
      final index = _titles.indexWhere((t) => '${t.media.kind}/${t.media.id}' == item.id);
      if (index < 0) return;
      if (_catalogSelection?.media != _titles[index].media) _catalogSelection = _titles[index];
      if (index >= _titles.length - 6) _moreCatalog();
    });
  }

  void _moreCatalog() {
    if (_catalogPageScheduled ||
        !PlatformDetector.isTV() ||
        !_catalogView ||
        _busy ||
        _error != null ||
        (_skip == null && _after == null)) {
      return;
    }
    _catalogPageScheduled = true;
    final epoch = _catalogEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _catalogPageScheduled = false;
      if (mounted && epoch == _catalogEpoch && PlatformDetector.isTV() && _catalogView && !_busy && _error == null) {
        unawaited(_load(more: true));
      }
    });
  }

  Widget _catalogShelf() {
    final epoch = _catalogEpoch;
    final id = 'catalog:$_section:$_catalogEpoch';
    final key = _hubKeys.putIfAbsent(id, GlobalKey<HubSectionState>.new);
    _stops.add((
      id,
      () {
        if (key.currentState == null) return false;
        key.currentState!.requestFocusFromMemory();
        return true;
      },
    ));
    return FocusTraversalOrder(
      order: NumericFocusOrder(_stops.length.toDouble()),
      child: HubSection(
        key: key,
        hub: _presentation.hub(
          TedHomeRow(_section == 'search' ? 'search-$_searchKind' : 'popular-$_section', _titles, false, const []),
        ),
        focusMemory: _catalogFocusMemory,
        icon: _catalogKind == 'movie' ? Icons.movie_outlined : Icons.tv,
        showHeader: false,
        autoScroll: false,
        artworkBuilder: _cachedPoster,
        onFocusedItemChanged: (item) {
          if (epoch == _catalogEpoch) _catalogFocused(item);
        },
        onNearEnd: () {
          if (epoch == _catalogEpoch) _moreCatalog();
        },
        onNavigateRight: () {
          if (epoch == _catalogEpoch) _moreCatalog();
        },
        onItemTap: (item) =>
            unawaited(_open(_titles.firstWhere((t) => _presentation.item(t).id == item.id), origin: id)),
        onItemLongPress: (item) => unawaited(_menu(_titles.firstWhere((t) => _presentation.item(t).id == item.id))),
        onBack: () => _focusSidebar(origin: id),
        onNavigateToSidebar: () => _focusSidebar(origin: id),
        onVerticalNavigation: (up) {
          _neighbour(id, up);
          return true;
        },
      ),
    );
  }

  double get _catalogContentInset {
    // Align with the artwork inside the existing Home shelf/grid cards,
    // preserving Plezy's gutter, card padding and keyboard focus border.
    if (PlatformDetector.isTV()) {
      final gap = math.max(4.0, SettingsService.instance.read(SettingsService.gridSpacing).gridGap);
      return TvLayoutConstants.shelfHorizontalInset + gap / 2 + 3;
    }
    return 24 + 3 + (InputModeTracker.isKeyboardMode(context) ? FocusTheme.focusBorderWidth : 0);
  }

  Widget _catalogControls() => _section == 'search'
      ? _searchControls()
      : _lane(
          'filters',
          TedCatalogFilters(
            horizontalInset: _catalogContentInset,
            mapped: _mappedOnly,
            watched: _watchFilter,
            genre: _genre,
            catalog: _catalog,
            onMapped: (value) => _changeCatalogFilters(() => _mappedOnly = value),
            onWatched: (value) => _changeCatalogFilters(() => _watchFilter = value),
            onGenre: (value) => _changeCatalogFilters(() => _genre = value),
            onCatalog: (value) => _changeCatalogFilters(() => _catalog = value),
          ),
        );

  void _submitSearch() => _changeCatalogFilters(() => _query = _search.text.trim());

  Widget _searchControls() => _lane(
    'search',
    Padding(
      padding: EdgeInsets.fromLTRB(_catalogContentInset, 12, _catalogContentInset, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final type = FocusTraversalOrder(
            order: const NumericFocusOrder(0),
            child: SizedBox(
              width: constraints.maxWidth >= 480 ? 180 : constraints.maxWidth,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('search-type'),
                focusNode: _searchTypeFocus,
                initialValue: _searchKind,
                decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder(), isDense: true),
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'movie', child: Text('Movies')),
                  DropdownMenuItem(value: 'series', child: Text('Series')),
                ],
                onChanged: (kind) {
                  if (kind != null && kind != _searchKind) _changeCatalogFilters(() => _searchKind = kind);
                },
              ),
            ),
          );
          final input = FocusTraversalOrder(
            order: const NumericFocusOrder(1),
            child: FocusableTextField(
              focusNode: _searchFocus,
              onNavigateUp: () => _neighbour('search', true),
              onNavigateDown: () => _neighbour('search', false),
              onNavigateLeft: _searchTypeFocus.requestFocus,
              onNavigateRight: _searchButtonFocus.requestFocus,
              onBack: () => _focusSidebar(origin: 'search'),
              controller: _search,
              decoration: InputDecoration(
                labelText: 'Search movies and series',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: IconButton(
                    focusNode: _searchButtonFocus,
                    tooltip: 'Search',
                    icon: const Icon(Icons.search),
                    onPressed: _submitSearch,
                  ),
                ),
              ),
              onSubmitted: (_) => _submitSearch(),
            ),
          );
          return constraints.maxWidth >= 480
              ? Row(
                  children: [
                    type,
                    const SizedBox(width: 16),
                    Expanded(child: input),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [type, const SizedBox(height: 12), input],
                );
        },
      ),
    ),
  );

  Widget _tvCatalogContent() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: ValueListenableBuilder<TedTitle?>(
          valueListenable: _catalogPreview,
          builder: (context, selection, _) => selection == null
              ? const SizedBox.shrink()
              : TedHomeBanner(
                  key: const ValueKey('catalog-banner'),
                  client: widget.client,
                  entries: [selection],
                  refreshEpoch: _catalogEpoch,
                  catalogPreview: true,
                  enrichMetadata: false,
                  contentHorizontalInset: _catalogContentInset,
                  onPlay: _playBanner,
                  onOpen: _open,
                  onBack: _focusSidebar,
                ),
        ),
      ),
      _catalogControls(),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null) _notice('error', _error!),
      if (_titles.isNotEmpty) _catalogShelf(),
      if (!_busy && _titles.isEmpty && _error == null)
        const Padding(padding: EdgeInsets.all(24), child: Text('No results.')),
      const SizedBox(height: 8),
    ],
  );

  bool hasPlaybackEpisode(TedMediaIdentity media) =>
      _details.lastOrNull is _MoviePage && (_details.last as _MoviePage).title.media == media;

  Future<void> openPlaybackEpisode(TedTitle title) async {
    final removed = <_DetailPage>[];
    while (_details.isNotEmpty &&
        (_details.last is _SeasonPage ||
            _details.last is _MoviePage && (_details.last as _MoviePage).title.media.kind == 'episode')) {
      removed.add(_details.removeLast());
    }
    if (_details.lastOrNull case final _SeriesPage page) {
      if (page.title.media.id != title.media.id.split(':').first) removed.add(_details.removeLast());
    }
    await _open(title);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final page in removed) {
        page.scope.dispose();
      }
    });
  }

  Future<void> _open(TedTitle title, {String? origin}) async {
    {
      final hub = _hubKeys.entries.where((entry) => entry.value.currentState?.hasFocus == true).firstOrNull;
      final lane = _laneKeys.entries.where((entry) => entry.value.currentState?.hasFocus == true).firstOrNull;
      if (_details.isEmpty) {
        _movieReturnStop =
            origin ??
            (hub == null
                ? lane?.key
                : hub.key.startsWith('catalog:')
                ? hub.key
                : 'hub:${hub.key}');
      }
      if (_details.isEmpty && _bannerKey.currentState?.controlsHaveFocus == true) _movieReturnStop = 'banner-controls';
      if (_details.isEmpty && _movieReturnStop == null && _section == 'home') _movieReturnStop = 'banner';
      final _DetailPage page = title.media.kind == 'series' ? _SeriesPage(title) : _MoviePage(title);
      setState(() {
        if (title.media.kind == 'episode') {
          final parent = title.parent ?? TedMediaIdentity('series', title.media.id.split(':').first);
          final season = title.season ?? int.parse(title.media.id.split(':')[1]);
          final existing = _details.lastOrNull;
          if (existing is! _SeasonPage || existing.title.media != parent || existing.season != season) {
            final show = existing is _SeriesPage && existing.title.media == parent
                ? existing.title
                : TedTitle(
                    parent,
                    title.seriesName,
                    '',
                    false,
                    0,
                    0,
                    false,
                    poster: title.poster,
                    background: title.background,
                    logo: title.logo,
                    seasons: [season],
                  );
            if (existing is! _SeriesPage || existing.title.media != parent) {
              _details.add(_SeriesPage(show)..visited = false);
            }
            _details.add(_SeasonPage(show, season, initialEpisode: title.media)..visited = false);
          }
        }
        _details.add(page);
      });
      page.scope.requestFocus();
      return;
    }
  }

  void _openSeason(TedTitle title, int season) {
    final page = _SeasonPage(title, season);
    setState(() => _details.add(page));
    page.scope.requestFocus();
  }

  void _openPerson(TedMetadataPerson person, TedTitle origin, TedMetadataSnapshot? metadata) {
    final page = _PersonPage(person, origin, metadata);
    setState(() => _details.add(page));
    page.scope.requestFocus();
  }

  /// Settings shares the browse shell and preserves the current page beneath it.
  void openSettings() {
    if (_details.lastOrNull is _SettingsPage) {
      if (InputModeTracker.currentMode == InputMode.keyboard) _details.last.requestFocus();
      return;
    }
    if (_details.any((page) => page is _SettingsPage)) return;
    final page = _SettingsPage();
    setState(() => _details.add(page));
    page.scope.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_details.lastOrNull, page)) page.requestFocus();
    });
  }

  void _openLicenses([MergedLicenseEntry? license]) {
    final page = _LicensesPage(license);
    setState(() => _details.add(page));
    page.scope.requestFocus();
  }

  void _closeDetail() {
    if (_details.isEmpty) return;
    final closed = _details.last;
    setState(() {
      _details.removeLast();
      if (_details.isNotEmpty) _details.last.visited = true;
    });
    (_details.isEmpty ? _contentScope : _details.last.scope).requestFocus();
    if (_details.isEmpty) _sidebarReturnStop = _movieReturnStop;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      closed.scope.dispose();
      if (mounted) {
        final page = _details.lastOrNull;
        if (page is _MoviePage) {
          page.key.currentState?.requestPlayFocus();
        } else {
          _focusMain(fromSidebar: true);
        }
      }
    });
    if (closed is _MoviePage || closed is _SeriesPage || closed is _SeasonPage) {
      if (_details.isNotEmpty) {
        unawaited(_details.last.reload());
      } else {
        final title = switch (closed) {
          _MoviePage(:final title) => title,
          _SeriesPage(:final title) => title,
          _SeasonPage(:final title) => title,
          _ => throw StateError('Unexpected detail page'),
        };
        unawaited(_refreshTitle(title, returnStop: _movieReturnStop));
      }
    }
  }

  KeyEventResult _handleBack(KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent != true) return KeyEventResult.ignored;
    return handleBackKeyAction(event, _goBack);
  }

  void _goBack() {
    if (_details.isNotEmpty) {
      _closeDetail();
    } else {
      _focusSidebar();
    }
  }

  bool _backWithoutFocus(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true || !event.logicalKey.isBackKey) return false;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == _browseFocus || (primary?.ancestors.contains(_browseFocus) ?? false)) return false;
    return _handleBack(event) == KeyEventResult.handled;
  }

  Future<void> _playDetail(_MoviePage page, TedTitle title, String? source, bool fromBeginning) async {
    try {
      await (widget.onPlaySelection?.call(title, source, fromBeginning) ?? widget.onPlay(title));
    } finally {
      // The route can return while its Play control is still disabled by the
      // enclosing work operation. Restore after that operation's next build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true && identical(_details.lastOrNull, page)) {
          page.key.currentState?.requestPlayFocus();
        }
      });
    }
  }

  Widget _playableDetail(_MoviePage page) {
    if (page.title.media.kind == 'episode') {
      return TedEpisodeDetail(
        key: page.key,
        downloads: widget.downloads,
        client: widget.client,
        initial: page.title,
        horizontalInset: _catalogContentInset,
        onClose: _closeDetail,
        onSidebar: () => _focusSidebar(origin: 'movie-detail'),
        onHeader: _focusDetailBack,
        onPerson: _openPerson,
        onPlay: (title, source, beginning) => _playDetail(page, title, source, beginning),
        onDownload:
            widget.onDownloadSelection ?? (widget.onDownload == null ? null : (title, _) => widget.onDownload!(title)),
      );
    }
    return TedMovieDetail(
      key: page.key,
      downloads: widget.downloads,
      client: widget.client,
      initial: page.title,
      horizontalInset: _catalogContentInset,
      onClose: _closeDetail,
      onSidebar: () => _focusSidebar(origin: 'movie-detail'),
      onHeader: _focusDetailBack,
      onPerson: _openPerson,
      onPlay: (title, source, beginning) => _playDetail(page, title, source, beginning),
      onDownload:
          widget.onDownloadSelection ?? (widget.onDownload == null ? null : (title, _) => widget.onDownload!(title)),
    );
  }

  Future<void> _playBanner(TedTitle title) async {
    try {
      await widget.onPlay(title);
      if (mounted) await _load();
    } on TedFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = const TedFailure('unavailable').message);
    }
  }

  Future<void> _refreshTitle(TedTitle title, {String? returnStop}) async {
    if (_section == 'home' || _personal(_section)) {
      await _load(returnStop: returnStop);
      return;
    }
    try {
      final fresh = await widget.client.title(title.media);
      if (mounted) {
        setState(() {
          _titles = [for (final item in _titles) item.media == fresh.media ? fresh : item];
          if (_catalogSelection?.media == fresh.media) _catalogSelection = fresh;
        });
      }
    } on TedFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = const TedFailure('unavailable').message);
    }
  }

  Future<void> _menu(TedTitle title) async {
    if (!title.media.playable) {
      await _open(title);
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => TedFocusRegion(
        grid: true,
        autofocus: true,
        onBack: () => Navigator.pop(context),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(title.name), subtitle: const Text('TED')),
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: Text(title.ready ? 'Play / Resume' : 'Find sources'),
                onTap: () => Navigator.pop(context, 'play'),
              ),
              if (title.media.kind == 'episode')
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('Reload thumbnails'),
                  onTap: () => Navigator.pop(context, 'thumbnails'),
                ),
              ListTile(
                leading: Icon(title.played ? Icons.remove_done : Icons.done),
                title: Text(title.played ? 'Mark unwatched' : 'Mark watched'),
                onTap: () => Navigator.pop(context, 'watch'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    try {
      if (action == 'thumbnails') {
        await _reload();
        return;
      }
      if (action == 'play') {
        await widget.onPlay(title);
      } else {
        await widget.client.setWatched(title, !title.played);
      }
      if (mounted) await _refreshTitle(title);
    } on TedFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = const TedFailure('unavailable').message);
    }
  }

  void _focusSidebar({String? origin}) {
    _sidebarReturnStop = origin;
    if (_wide) {
      _navFocus[_sidebarOrigin].requestFocus();
    } else {
      _bottomKey.currentState?.requestFocus();
    }
  }

  void _focusControls() => _controlsKey.currentState?.requestFocus(first: true);

  void _focusDetailBack() => _detailBackKey.currentState?.requestFocus();

  bool get _settingsVisible => _details.lastOrNull is _SettingsPage || _details.lastOrNull is _LicensesPage;

  Widget _controls({required bool compact, bool collapsed = false}) => TedFocusRegion(
    key: _controlsKey,
    grid: true,
    scroll: false,
    onUp: compact ? _focusMain : () => _navFocus.last.requestFocus(),
    onDown: compact ? () => _bottomKey.currentState?.requestFocus(first: true) : null,
    onRight: compact ? null : () => _focusMain(fromSidebar: true),
    onBack: () => _focusSidebar(origin: _sidebarReturnStop),
    child: TedSidebarControls(
      displayName: widget.displayName,
      profilePicture: widget.profilePicture,
      onReload: _busy ? null : _reload,
      onSettings: widget.onSettings ?? openSettings,
      settingsSelected: _settingsVisible,
      onSignOut: widget.onSignOut,
      onSwitchProfile: widget.onSwitchProfile,
      onChangeServer: widget.onChangeServer,
      compact: compact,
      collapsed: collapsed,
      onAccountMenuChanged: (open) {
        if (mounted) setState(() => _sidebarMenuOpen = open);
      },
    ),
  );

  void _revealFirstHomeRow() {
    if (_continueRevealPending || !PlatformDetector.isTV() || InputModeTracker.currentMode != InputMode.keyboard) {
      return;
    }
    _continueRevealPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _continueRevealPending = false;
      if (!mounted ||
          _section != 'home' ||
          InputModeTracker.currentMode != InputMode.keyboard ||
          !PlatformDetector.isTV() ||
          InputModeTracker.currentMode != InputMode.keyboard ||
          !(ModalRoute.of(context)?.isCurrent ?? false)) {
        return;
      }
      final first = _rows.where((row) => row.titles.isNotEmpty).firstOrNull;
      final hub = _hubKeys[first?.id]?.currentState;
      if (hub == null || !hub.hasFocus) return;
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
      // Plezy's shelf includes its inter-row gap. TED's negative reveal
      // offset moves that existing blank space below the viewport edge.
      final bottom = shelf.localToGlobal(Offset(0, shelf.size.height), ancestor: viewport).dy;
      final position = scroll.position;
      final target = (position.pixels + bottom - viewport.size.height - 18).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() < 1) return;
      unawaited(position.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic));
    });
  }

  void _focusMain({bool fromSidebar = false}) {
    if (_details.isEmpty && _section == 'downloads' && (_downloadsKey.currentState?.requestFocus() ?? false)) return;
    if (_details.isNotEmpty) {
      if (fromSidebar &&
          _sidebarReturnStop == 'detail-back' &&
          (_detailBackKey.currentState?.requestFocus() ?? false)) {
        return;
      }
      _details.last.requestFocus();
      return;
    }
    if (fromSidebar) {
      if (_sidebarReturnStop == 'controls' && (_controlsKey.currentState?.requestFocus() ?? false)) return;
      if (_sidebarReturnStop == 'banner' && (_bannerKey.currentState?.requestFocusFromMemory() ?? false)) return;
      if (_sidebarReturnStop == 'banner-controls' && (_bannerKey.currentState?.requestControlsFocus() ?? false)) return;
      final remembered = _stops.where((stop) => stop.$1 == _sidebarReturnStop).firstOrNull;
      if (remembered != null && remembered.$2()) return;
    }
    if (fromSidebar && _catalogView) {
      if (PlatformDetector.isTV()) {
        final shelf = _hubKeys['catalog:$_section:$_catalogEpoch']?.currentState;
        if (shelf != null) {
          shelf.requestFocusFromMemory();
          return;
        }
      } else if (_laneKeys['grid:$_section']?.currentState?.requestFocus() ?? false) {
        return;
      }
    }
    if (_section == 'home' && (_bannerKey.currentState?.requestFocus() ?? false)) return;
    for (final stop in _stops) {
      if (stop.$2()) return;
    }
    _focusControls();
  }

  void _neighbour(String id, bool up) {
    if (up &&
        _section == 'home' &&
        PlatformDetector.isTV() &&
        id == 'hub:${_rows.where((row) => row.titles.isNotEmpty).firstOrNull?.id}') {
      return;
    }
    final index = _stops.indexWhere((stop) => stop.$1 == id);
    if (index < 0) return;
    for (var i = index + (up ? -1 : 1); i >= 0 && i < _stops.length; i += up ? -1 : 1) {
      if (_stops[i].$2()) return;
    }
    // The top edge stays in the page. Reload now belongs to the sidebar,
    // which is entered explicitly with Left rather than vertical navigation.
    if (up && _section == 'home') {
      _bannerKey.currentState?.requestControlsFocus();
    }
  }

  Widget _lane(String id, Widget child, {bool grid = false}) {
    final key = _laneKeys.putIfAbsent(id, GlobalKey<TedFocusRegionState>.new);
    _stops.add((id, () => key.currentState?.requestFocus() ?? false));
    return FocusTraversalOrder(
      order: NumericFocusOrder(_stops.length.toDouble()),
      child: TedFocusRegion(
        key: key,
        grid: grid,
        textInputNode: id == 'search' ? _searchFocus : null,
        onUp: () => _neighbour(id, true),
        onDown: () => _neighbour(id, false),
        onLeft: () => _focusSidebar(origin: id),
        onBack: () => _focusSidebar(origin: id),
        child: child,
      ),
    );
  }

  Widget _notice(String id, String message) {
    final notice = TedNotice(message, retry: _busy ? null : () => _load(more: id == 'error' && _failedMore));
    return _busy ? notice : _lane(id, notice);
  }

  Widget _homeHub(TedHomeRow row) {
    final id = 'hub:${row.id}';
    final first = _rows.where((candidate) => candidate.titles.isNotEmpty).firstOrNull?.id == row.id;
    final key = _hubKeys.putIfAbsent(row.id, GlobalKey<HubSectionState>.new);
    _stops.add((
      id,
      () {
        final state = key.currentState;
        if (state == null) return false;
        state.requestFocusFromMemory();
        return true;
      },
    ));
    return FocusTraversalOrder(
      key: ValueKey('ted-home-row:${row.id}'),
      order: NumericFocusOrder(_stops.length.toDouble()),
      child: KeyedSubtree(
        key: ValueKey(row.id),
        child: HubSection(
          key: key,
          hub: _presentation.hub(row),
          episodePosterModeOverride: _personal(row.id) ? EpisodePosterMode.episodeThumbnail : null,
          artworkBuilder: _personal(row.id) ? _personalBuilder : _cachedPoster,
          focusMemory: _focusMemory,
          focusScrollAlignment: .18,
          autoScroll: !first || !PlatformDetector.isTV(),
          onFocusedItemChanged: first ? (_) => _revealFirstHomeRow() : null,
          icon: switch (row.id) {
            'continue-watching' => Icons.history,
            'new-releases' => Icons.new_releases_outlined,
            _ => Icons.movie_outlined,
          },
          onItemTap: (item) =>
              unawaited(_open(row.titles.firstWhere((t) => _presentation.item(t).id == item.id), origin: id)),
          onItemLongPress: (item) =>
              unawaited(_menu(row.titles.firstWhere((t) => _presentation.item(t).id == item.id))),
          onBack: () => _focusSidebar(origin: id),
          onNavigateToSidebar: () => _focusSidebar(origin: id),
          onVerticalNavigation: (up) {
            _neighbour(id, up);
            return true;
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TedDefaultFocus(
    restore: () => _focusMain(fromSidebar: true),
    child: SettingsBuilder(
      prefs: const [
        SettingsService.libraryDensity,
        SettingsService.episodePosterMode,
        SettingsService.gridSpacing,
        SettingsService.alwaysKeepSidebarOpen,
      ],
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          final gridCardWidth = wide ? 180.0 : (constraints.maxWidth - 64) / 2;
          _wide = wide;
          final keyboardMode = InputModeTracker.isKeyboardMode(context);
          final sidebarExpanded =
              SettingsService.instance.read(SettingsService.alwaysKeepSidebarOpen) ||
              _sidebarHovered ||
              _sidebarMenuOpen ||
              (_sidebarFocus.hasFocus && keyboardMode);
          final sidebarWidth = !wide
              ? 0.0
              : sidebarExpanded
              ? NavigationRailLayout.expandedWidth
              : NavigationRailLayout.collapsedWidth;
          _stops.clear();
          final firstRow = _rows.where((row) => row.titles.isNotEmpty).firstOrNull;
          double? bannerMaxHeight;
          if (wide && firstRow != null) {
            final mode = _personal(firstRow.id)
                ? EpisodePosterMode.episodeThumbnail
                : SettingsService.instance.read(SettingsService.episodePosterMode);
            final items = _presentation.hub(firstRow).items;
            final hasWide = items.any((item) => item.usesWideAspectRatio(mode));
            final useWide =
                hasWide &&
                (items.every((item) => item.usesWideAspectRatio(mode)) || mode == EpisodePosterMode.episodeThumbnail);
            final cardWidth = MediaGridDelegate.cellWidth(
              context: context,
              availableWidth: constraints.maxWidth - sidebarWidth,
              density: SettingsService.instance.read(SettingsService.libraryDensity),
              useWideAspectRatio: useWide,
            );
            // Shelf heading, captions/focus room and current inter-row gap.
            final rowHeight = (cardWidth - 6) * (useWide ? 9 / 16 : 1.5) + 140;
            bannerMaxHeight = constraints.maxHeight - rowHeight;
          }
          final selected = _settingsVisible ? -1 : _sections.indexOf(_section);
          final browseContent = FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: _section == 'downloads' && widget.downloads != null
                ? TedDownloadsScreen(
                    key: _downloadsKey,
                    downloads: widget.downloads!,
                    embedded: true,
                    horizontalInset: _catalogContentInset,
                    onSidebar: () => _focusSidebar(origin: 'downloads'),
                    onReady: _scheduleActivatedFocus,
                  )
                : _catalogView && PlatformDetector.isTV()
                ? _tvCatalogContent()
                : SingleChildScrollView(
                    key: PageStorageKey('ted-browse-$_section'),
                    padding: EdgeInsets.only(
                      top: _section == 'home' && _rows.any((row) => row.titles.isNotEmpty)
                          ? 0
                          : MediaQuery.paddingOf(context).top + 88,
                      bottom: 20,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_section == 'home' && _rows.any((row) => row.titles.isNotEmpty)) ...[
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(0),
                            child: TedHomeBanner(
                              key: _bannerKey,
                              client: widget.client,
                              entries: selectTedHomeBanner(_rows),
                              refreshEpoch: _generation,
                              maxHeight: bannerMaxHeight,
                              onPlay: _playBanner,
                              onOpen: _open,
                              onBack: () => _focusSidebar(
                                origin: _bannerKey.currentState?.controlsHaveFocus == true
                                    ? 'banner-controls'
                                    : 'banner',
                              ),
                              onNavigateDown: () {
                                for (final stop in _stops) {
                                  if (stop.$2()) return;
                                }
                              },
                            ),
                          ),
                          const SizedBox(height: 32 * ContentLayoutConstants.rowGapScale),
                        ],
                        if (_busy && (_section != 'home' || !_rows.any((row) => row.titles.isNotEmpty)))
                          const LinearProgressIndicator(),
                        if (_error != null) _notice('error', _error!),
                        for (var i = 0; i < _issues.length; i++) _notice('issue:$i', _issues[i].message),
                        if (_catalogView) _catalogControls(),
                        if (_section == 'home')
                          for (final row in _rows) ...[
                            for (var i = 0; i < row.issues.length; i++)
                              _notice('row-issue:${row.id}:$i', row.issues[i].message),
                            if (row.unavailable)
                              _notice(
                                'row-unavailable:${row.id}',
                                '${TedPresentation.rowName(row.id)} is unavailable.',
                              ),
                            if (row.titles.isNotEmpty) _homeHub(row),
                          ],
                        if (_titles.isNotEmpty)
                          _lane(
                            'grid:$_section',
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Wrap(
                                spacing: 16,
                                runSpacing: 24 * ContentLayoutConstants.rowGapScale,
                                children: [
                                  for (final title in _titles)
                                    SizedBox(
                                      width: gridCardWidth,
                                      child: FocusableWrapper(
                                        key: ValueKey(title.media),
                                        onSelect: () => unawaited(_open(title, origin: 'grid:$_section')),
                                        onLongPress: () => unawaited(_menu(title)),
                                        onBack: () => _focusSidebar(origin: 'grid:$_section'),
                                        child: MediaCard(
                                          item: _presentation.item(title),
                                          width: gridCardWidth,
                                          // Match HubSection: height is artwork only;
                                          // MediaCard adds its padding and captions.
                                          height:
                                              (gridCardWidth - 6) *
                                              (_personal(_section) && title.media.kind == 'episode' ? 9 / 16 : 1.5),
                                          episodePosterModeOverride: _personal(_section)
                                              ? EpisodePosterMode.episodeThumbnail
                                              : null,
                                          artworkBuilder: _personal(_section) ? _personalBuilder : _cachedPoster,
                                          viewModeOverride: ViewMode.grid,
                                          onTap: () => unawaited(_open(title, origin: 'grid:$_section')),
                                          onLongPress: () => unawaited(_menu(title)),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            grid: true,
                          ),
                        if (!_busy && _section != 'home' && _titles.isEmpty && _error == null && _issues.isEmpty)
                          Padding(padding: const EdgeInsets.all(24), child: Text('No results.')),
                        if (_after != null || _skip != null)
                          _lane(
                            'paging',
                            Center(
                              child: OutlinedButton(
                                onPressed: _busy ? null : () => _load(more: true),
                                child: const Text('Load more'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          );
          final content = Stack(
            children: [
              Positioned.fill(
                child: FocusScope(
                  node: _contentScope,
                  child: TickerMode(
                    enabled: _details.isEmpty,
                    child: ExcludeFocus(
                      excluding: _details.isNotEmpty,
                      child: Offstage(offstage: _details.isNotEmpty, child: browseContent),
                    ),
                  ),
                ),
              ),
              for (final page in _details)
                if (page.visited)
                  Positioned.fill(
                    child: FocusScope(
                      node: page.scope,
                      child: TickerMode(
                        enabled: identical(page, _details.last),
                        child: ExcludeFocus(
                          excluding: !identical(page, _details.last),
                          child: Offstage(
                            offstage: !identical(page, _details.last),
                            child: switch (page) {
                              _MoviePage() => _playableDetail(page),
                              _SeriesPage() => TedSeriesDetail(
                                key: page.key,
                                downloads: widget.downloads,
                                client: widget.client,
                                initial: page.title,
                                horizontalInset: _catalogContentInset,
                                onClose: _closeDetail,
                                onSidebar: () => _focusSidebar(origin: 'show-detail'),
                                onHeader: _focusDetailBack,
                                onSeason: (season) => _openSeason(page.key.currentState?.title ?? page.title, season),
                                onDownload: widget.onDownloadSeries,
                                onPerson: _openPerson,
                              ),
                              _SeasonPage() => TedSeasonDetail(
                                key: page.key,
                                downloads: widget.downloads,
                                client: widget.client,
                                show: page.title,
                                season: page.season,
                                initialEpisode: page.initialEpisode,
                                horizontalInset: _catalogContentInset,
                                onClose: _closeDetail,
                                onSidebar: () => _focusSidebar(origin: 'season-detail'),
                                onHeader: _focusDetailBack,
                                onEpisode: (title) => unawaited(_open(title)),
                                onDownload: widget.onDownloadSeason,
                                onPerson: _openPerson,
                              ),
                              _PersonPage() => TedPersonDetail(
                                key: page.key,
                                client: widget.client,
                                person: page.person,
                                origin: page.origin,
                                originMetadata: page.metadata,
                                horizontalInset: _catalogContentInset,
                                onClose: _closeDetail,
                                onSidebar: () => _focusSidebar(origin: 'person-detail'),
                                onHeader: _focusDetailBack,
                                onOpen: (title) => unawaited(_open(title)),
                              ),
                              _SettingsPage() => TeddySettingsScreen(
                                key: page.key,
                                downloads: widget.downloads,
                                onLayoutRestart: widget.onLayoutRestart ?? () {},
                                onBackPressed: _closeDetail,
                                onSidebar: () => _controlsKey.currentState?.requestFocus(),
                                onLicenses: _openLicenses,
                              ),
                              _LicensesPage(:final license) =>
                                license == null
                                    ? LicensesScreen(
                                        focusKey: page.key,
                                        onBackPressed: _closeDetail,
                                        onOpenLicense: _openLicenses,
                                      )
                                    : LicenseDetailScreen(
                                        focusKey: page.key,
                                        mergedLicense: license,
                                        onBackPressed: _closeDetail,
                                      ),
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          );
          final browse = Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (wide)
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: FocusTraversalGroup(
                          policy: WidgetOrderTraversalPolicy(),
                          child: MouseRegion(
                            onEnter: (_) => setState(() => _sidebarHovered = true),
                            onExit: (_) => setState(() => _sidebarHovered = false),
                            child: Focus(
                              focusNode: _sidebarFocus,
                              canRequestFocus: false,
                              onFocusChange: (_) => setState(() {}),
                              child: AnimatedContainer(
                                key: const ValueKey('ted-sidebar'),
                                width: sidebarWidth,
                                duration: NavigationRailLayout.expandDuration,
                                curve: NavigationRailLayout.expandCurve,
                                onEnd: _revealFirstHomeRow,
                                clipBehavior: Clip.hardEdge,
                                decoration: const BoxDecoration(),
                                child: AnimatedPadding(
                                  duration: NavigationRailLayout.expandDuration,
                                  curve: NavigationRailLayout.expandCurve,
                                  padding: EdgeInsets.fromLTRB(
                                    sidebarExpanded ? 12 : 4,
                                    MediaQuery.paddingOf(context).top + 56,
                                    sidebarExpanded ? 12 : 4,
                                    12,
                                  ),
                                  child: Column(
                                    children: [
                                      Expanded(
                                        child: SingleChildScrollView(
                                          child: Column(
                                            children: [
                                              for (var i = 0; i < _sections.length; i++)
                                                Focus(
                                                  canRequestFocus: false,
                                                  skipTraversal: true,
                                                  onFocusChange: (focused) {
                                                    if (focused && _activationOrigin != _navFocus[i]) {
                                                      _activationOrigin = null;
                                                    }
                                                    if (!focused ||
                                                        InputModeTracker.currentMode != InputMode.keyboard ||
                                                        ModalRoute.of(context)?.isCurrent == false) {
                                                      return;
                                                    }
                                                    WidgetsBinding.instance.addPostFrameCallback((_) {
                                                      final node = _navFocus[i];
                                                      if (mounted &&
                                                          InputModeTracker.currentMode == InputMode.keyboard &&
                                                          node.hasFocus &&
                                                          node.context != null) {
                                                        Scrollable.ensureVisible(
                                                          node.context!,
                                                          duration: const Duration(milliseconds: 150),
                                                          alignmentPolicy:
                                                              ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                                                        );
                                                      }
                                                    });
                                                  },
                                                  onKeyEvent: (_, event) {
                                                    if (!event.isActionable) return KeyEventResult.ignored;
                                                    if (event.logicalKey.isLeftKey) return KeyEventResult.handled;
                                                    if (event.logicalKey.isRightKey) {
                                                      _focusMain(fromSidebar: true);
                                                      return KeyEventResult.handled;
                                                    }
                                                    if (event.logicalKey.isUpKey || event.logicalKey.isDownKey) {
                                                      if (event.logicalKey.isDownKey && i == _sections.length - 1) {
                                                        _focusControls();
                                                        return KeyEventResult.handled;
                                                      }
                                                      final next = (i + (event.logicalKey.isUpKey ? -1 : 1)).clamp(
                                                        0,
                                                        _sections.length - 1,
                                                      );
                                                      _navFocus[next].requestFocus();
                                                      return KeyEventResult.handled;
                                                    }
                                                    return KeyEventResult.ignored;
                                                  },
                                                  child: ClickableCursor(
                                                    child: NavigationRailItem(
                                                      icon: _icons[i],
                                                      label: Text(TedPresentation.rowName(_sections[i])),
                                                      isSelected: selected == i,
                                                      mouseCursor: SystemMouseCursors.click,
                                                      isCollapsed: !sidebarExpanded,
                                                      collapsedLabel: TedPresentation.rowName(_sections[i]),
                                                      collapsedContentWidth: TedSidebarControls.collapsedContentWidth,
                                                      onTap: () => _activateSection(_sections[i]),
                                                      focusNode: _navFocus[i],
                                                      autofocus: _sections[i] == _section,
                                                      onNavigateRight: () {
                                                        _focusMain(fromSidebar: true);
                                                      },
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      _controls(compact: false, collapsed: !sidebarExpanded),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: FocusTraversalOrder(order: const NumericFocusOrder(2), child: content),
                          ),
                          if (!_settingsVisible) const Positioned(top: 0, left: 0, right: 0, child: TedBrowseHeader()),
                          if (_details.isNotEmpty && !_settingsVisible)
                            Positioned(
                              top: MediaQuery.paddingOf(context).top,
                              left: 8,
                              child: TedFocusRegion(
                                key: _detailBackKey,
                                scroll: false,
                                onDown: _focusMain,
                                onLeft: () => _focusSidebar(origin: 'detail-back'),
                                onBack: _closeDetail,
                                child: DesktopTitleBarPadding(
                                  child: AppBarBackButton(
                                    key: const ValueKey('ted-detail-back'),
                                    style: BackButtonStyle.plain,
                                    color: Colors.white,
                                    onPressed: _closeDetail,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!wide) _controls(compact: true),
              if (!wide)
                TedFocusRegion(
                  key: _bottomKey,
                  scroll: false,
                  onUp: _focusMain,
                  child: NavigationBar(
                    selectedIndex: selected < 0 ? 0 : selected,
                    onDestinationSelected: (i) => _activateSection(_sections[i]),
                    destinations: [
                      for (var i = 0; i < _sections.length; i++)
                        NavigationDestination(icon: Icon(_icons[i]), label: TedPresentation.rowName(_sections[i])),
                    ],
                  ),
                ),
            ],
          );
          final ordered = FocusTraversalGroup(policy: OrderedTraversalPolicy(), child: browse);
          return TedBackScope(
            onBack: _goBack,
            child: Focus(
              focusNode: _browseFocus,
              canRequestFocus: false,
              onKeyEvent: (_, event) => _handleBack(event),
              child: wide ? SideNavigationScope(child: ordered) : ordered,
            ),
          );
        },
      ),
    ),
  );
}

class TedNotice extends StatelessWidget {
  final String message;
  final VoidCallback? retry;
  const TedNotice(this.message, {super.key, this.retry});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    child: Card(
      child: ListTile(
        leading: const Icon(Icons.info_outline),
        title: Text(message),
        trailing: retry == null ? null : TextButton(onPressed: retry, child: const Text('Retry')),
      ),
    ),
  );
}

class TedDetailScreen extends StatefulWidget {
  final TedClient client;
  final TedTitle initial;
  final TedPlay onPlay;
  final TedPlay? onDownload;
  const TedDetailScreen({
    super.key,
    required this.client,
    required this.initial,
    required this.onPlay,
    this.onDownload,
  });
  @override
  State<TedDetailScreen> createState() => _TedDetailScreenState();
}

class _TedDetailScreenState extends State<TedDetailScreen> {
  late TedTitle _title = widget.initial;
  List<TedTitle> _episodes = [];
  int? _season, _next;
  int _generation = 0;
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _work(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on TedFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = const TedFailure('unavailable').message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() => _work(() async {
    final title = await widget.client.title(_title.media);
    if (!mounted) return;
    setState(() {
      _title = title;
      if (!title.seasons.contains(_season)) {
        _season = title.seasons.where((s) => s > 0).firstOrNull ?? title.seasons.firstOrNull;
      }
    });
    if (_season != null) await _loadEpisodes();
  });
  Future<void> _loadEpisodes({bool more = false}) async {
    final generation = ++_generation;
    final page = await widget.client.episodes(_title.media.id, _season!, after: more ? _next : null);
    if (!mounted || generation != _generation) return;
    setState(() {
      _episodes = more
          ? {
              for (final e in [..._episodes, ...page.titles]) e.media: e,
            }.values.toList()
          : page.titles;
      _next = page.nextAfter;
    });
  }

  Future<void> _play(TedTitle title) => _work(() async {
    await widget.onPlay(title);
    if (mounted) await _reload();
  });
  void _openEpisode(TedTitle episode) {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute(
            builder: (_) => TedDetailScreen(
              client: widget.client,
              initial: episode,
              onPlay: widget.onPlay,
              onDownload: widget.onDownload,
            ),
          ),
        )
        .then((_) {
          if (mounted) unawaited(_reload());
        });
  }

  @override
  Widget build(BuildContext context) {
    final presentation = TedPresentation(widget.client);
    return TedFocusRegion(
      grid: true,
      autofocus: true,
      onBack: () => Navigator.of(context).pop(),
      child: Scaffold(
        appBar: TedAppBar(
          title: Text(_title.name),
          actions: [IconButton(tooltip: 'Reload', onPressed: _busy ? null : _reload, icon: const Icon(Icons.refresh))],
        ),
        body: ListView(
          key: PageStorageKey(_title.media),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) TedNotice(_error!, retry: _busy ? null : _reload),
            for (final issue in _title.issues) TedNotice(issue.message, retry: _busy ? null : _reload),
            if (_title.background.isNotEmpty || _title.poster.isNotEmpty)
              LayoutBuilder(
                builder: (context, constraints) {
                  final height = MediaQuery.sizeOf(context).width < 600 ? 220.0 : 400.0;
                  return SizedBox(
                    height: height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CyclingMediaBackdrop(
                          mediaKey: _title.media,
                          imagePaths: [_title.background],
                          fallbackImagePaths: [_title.poster],
                          client: null,
                          width: constraints.maxWidth,
                          height: height,
                          fallbackColor: Theme.of(context).scaffoldBackgroundColor,
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Theme.of(context).scaffoldBackgroundColor],
                            ),
                          ),
                        ),
                        if (_title.logo.isNotEmpty)
                          Positioned(
                            left: 24,
                            bottom: 24,
                            child: Image.network(
                              _title.logo,
                              width: constraints.maxWidth.clamp(0, 360) - 48,
                              height: 100,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => const SizedBox.shrink(),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title.episodeName.isNotEmpty ? _title.episodeName : _title.name,
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  Text(
                    [
                      _title.year,
                      _title.runtime,
                      if (_title.rating != null) '${_title.rating} ★',
                      ..._title.genres,
                    ].where((s) => s.isNotEmpty).join(' · '),
                  ),
                  const SizedBox(height: 16),
                  if (_title.media.playable)
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _play(_title),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(
                            !_title.ready
                                ? 'Find sources'
                                : _title.positionMs > 0
                                ? 'Resume ${Duration(milliseconds: _title.positionMs).toString().split('.').first}'
                                : 'Play',
                          ),
                        ),
                        if (widget.onDownload != null)
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _work(() => widget.onDownload!(_title)),
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('Download'),
                          ),
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _work(() async {
                                  await widget.client.setWatched(_title, !_title.played);
                                  if (mounted) await _reload();
                                }),
                          icon: Icon(_title.played ? Icons.done : Icons.check),
                          label: Text(_title.played ? 'Mark unwatched' : 'Mark watched'),
                        ),
                        if (_title.parent != null)
                          TextButton(
                            onPressed: () => _work(() async {
                              final parent = await widget.client.title(_title.parent!);
                              if (!mounted || !context.mounted) return;
                              await Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) => TedDetailScreen(
                                    client: widget.client,
                                    initial: parent,
                                    onPlay: widget.onPlay,
                                    onDownload: widget.onDownload,
                                  ),
                                ),
                              );
                            }),
                            child: const Text('Go to series'),
                          ),
                      ],
                    ),
                  const SizedBox(height: 20),
                  Text(_title.description, style: Theme.of(context).textTheme.bodyLarge),
                  if (_title.media.kind == 'series') ...[
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final season in _title.seasons)
                          ChoiceChip(
                            label: Text(season == 0 ? 'Specials' : 'Season $season'),
                            selected: _season == season,
                            onSelected: _busy
                                ? null
                                : (_) {
                                    setState(() {
                                      _season = season;
                                      _episodes = [];
                                      _next = null;
                                    });
                                    unawaited(_work(_loadEpisodes));
                                  },
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 16,
                      runSpacing: 20,
                      children: [
                        for (final episode in _episodes)
                          SizedBox(
                            width: 230,
                            child: FocusableWrapper(
                              key: ValueKey(episode.media),
                              onSelect: () => _openEpisode(episode),
                              onLongPress: () => unawaited(_play(episode)),
                              child: MediaCard(
                                item: presentation.item(episode),
                                width: 230,
                                height: 210,
                                viewModeOverride: ViewMode.grid,
                                episodePosterModeOverride: EpisodePosterMode.episodeThumbnail,
                                onTap: () => _openEpisode(episode),
                                onLongPress: () => unawaited(_play(episode)),
                                showTitleImplied: true,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (_next != null)
                      TextButton(
                        onPressed: _busy ? null : () => _work(() => _loadEpisodes(more: true)),
                        child: const Text('Load more episodes'),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
