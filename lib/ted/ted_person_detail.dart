import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../focus/locked_hub_controller.dart';
import '../focus/input_mode_tracker.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../utils/media_image_helper.dart';
import '../utils/layout_constants.dart';
import '../utils/platform_detector.dart';
import '../widgets/cycling_media_backdrop.dart';
import '../widgets/hub_section.dart';
import 'ted_client.dart';
import 'ted_focus_region.dart';
import 'ted_metadata_models.dart';
import 'ted_presentation.dart';
import 'ted_character_names.dart';

/// Person enrichment begins here, never while displaying the parent cast.
/// Credits are summaries; only opening an appearance requests title details.
class TedPersonDetail extends StatefulWidget {
  final TedClient client;
  final TedMetadataPerson person;
  final TedTitle origin;
  final TedMetadataSnapshot? originMetadata;
  final double horizontalInset;
  final VoidCallback onClose, onSidebar, onHeader;
  final ValueChanged<TedTitle> onOpen;
  const TedPersonDetail({
    super.key,
    required this.client,
    required this.person,
    required this.origin,
    this.originMetadata,
    required this.horizontalInset,
    required this.onClose,
    required this.onSidebar,
    required this.onHeader,
    required this.onOpen,
  });
  @override
  State<TedPersonDetail> createState() => TedPersonDetailState();
}

class TedPersonDetailState extends State<TedPersonDetail> {
  final _scroll = ScrollController();
  bool _revealPending = false;
  final _watchedKey = GlobalKey<HubSectionState>();
  final _otherKey = GlobalKey<HubSectionState>();
  final _controls = GlobalKey<TedFocusRegionState>();
  final _readMore = FocusNode(debugLabel: 'ted-person-read-more');
  final _memory = HubFocusMemory();
  late _PersonArtwork _artwork = _PersonArtwork(widget.client);
  TedMetadataSnapshot? _person;
  List<TedFilmographyEntry> _entries = [];
  bool _busy = true, _opening = false, _focusOnLoad = true;
  int _generation = 0;
  String _lastLane = 'watched';
  String? _error;
  List<TedFilmographyEntry> get _watched => _entries.where((v) => v.hasViewing).toList();
  List<TedFilmographyEntry> get _other => _entries.where((v) => !v.hasViewing).toList();

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void didUpdateWidget(TedPersonDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client || oldWidget.person.id != widget.person.id || !_artwork.valid) {
      _artwork.dispose();
      _artwork = _PersonArtwork(widget.client);
      _person = null;
      _entries = [];
      _opening = false;
      _focusOnLoad = true;
      unawaited(reload());
    }
  }

  @override
  void dispose() {
    _generation++;
    _artwork.dispose();
    _scroll.dispose();
    _readMore.dispose();
    super.dispose();
  }

  bool _current(int generation) => mounted && generation == _generation && _artwork.valid;

  Future<void> reload() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Bounded progressive polling for asynchronous person/credit jobs. A
      // partial/error result retains the usable biography and complete pages.
      for (var attempt = 0; attempt < 30 && _current(generation); attempt++) {
        final person = await widget.client.person(widget.person.id);
        if (!_current(generation)) return;
        setState(() => _person = person);
        final entries = <String, TedFilmographyEntry>{};
        final cursors = <String>{};
        String? after;
        var pending = false;
        do {
          final page = await widget.client.filmography(widget.person.id, after: after);
          pending = pending || page.pending;
          if (!_current(generation)) return;
          for (final entry in page.items) {
            if (entries.containsKey(entry.id)) throw const FormatException('Repeated filmography entry');
            entries[entry.id] = entry;
          }
          after = page.nextAfter;
          if (after != null && (!cursors.add(after) || cursors.length >= 200)) {
            throw const FormatException('Invalid filmography cursor');
          }
        } while (after != null);
        final sorted = entries.values.toList()
          ..sort((a, b) {
            final year = (b.year ?? 0).compareTo(a.year ?? 0);
            return year != 0 ? year : a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
        final wasFirst = _watched.isEmpty;
        setState(() => _entries = sorted);
        if (wasFirst != _watched.isEmpty && _lastLane == 'other') _revealOtherAfterInsertion();
        _focusReady();
        if (!person.pending &&
            !pending &&
            !sorted.any((v) => v.identityStatus == 'new' || v.identityStatus == 'queued')) {
          break;
        }
        if (attempt == 29) {
          setState(() => _error = 'Some person details are still being prepared. Retry to check again.');
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (_current(generation) && _person?.unavailable == true) {
        setState(() => _error = 'Some person details are unavailable. Cached information is shown.');
      }
    } catch (error) {
      if (_current(generation)) {
        setState(
          () => _error = error is FormatException
              ? 'TED returned an incomplete filmography.'
              : error is Exception
              ? 'Person details could not be loaded. Retry to check again.'
              : 'Person details could not be loaded.',
        );
      }
    } finally {
      if (_current(generation)) {
        setState(() => _busy = false);
        _focusReady();
      }
    }
  }

  void _focusReady() {
    if (!_focusOnLoad || (_busy && _entries.isEmpty)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusOnLoad && requestFocus()) _focusOnLoad = false;
    });
  }

  bool requestFocus() {
    if (_lastLane == 'controls' && (_controls.currentState?.requestFocus() ?? false)) return true;
    if (_lastLane == 'other' && _other.isNotEmpty && _otherKey.currentState != null) {
      _otherKey.currentState!.requestFocusFromMemory();
      return true;
    }
    if (_watched.isNotEmpty && _watchedKey.currentState != null) {
      _watchedKey.currentState!.requestFocusFromMemory();
      return true;
    }
    if (_other.isNotEmpty && _otherKey.currentState != null) {
      _otherKey.currentState!.requestFocusFromMemory();
      return true;
    }
    return _focusControls();
  }

  bool _focusControls() {
    if (_controls.currentState?.requestFocus() ?? false) return true;
    widget.onHeader();
    return true;
  }

  void _focusRow(bool watched) {
    final key = watched ? _watchedKey : _otherKey;
    if ((watched ? _watched : _other).isNotEmpty && key.currentState != null) {
      key.currentState!.requestFocusFromMemory();
    } else {
      _focusControls();
    }
  }

  void _focusBiography() {
    if (_readMore.context != null) {
      _readMore.requestFocus();
    } else {
      _focusControls();
    }
  }

  void _revealFirstRow() {
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

  void _revealOtherAfterInsertion() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          InputModeTracker.currentMode != InputMode.keyboard ||
          ModalRoute.of(context)?.isCurrent == false ||
          _lastLane != 'other') {
        return;
      }
      final row = _otherKey.currentContext;
      if (row == null || _otherKey.currentState?.hasFocus != true) {
        return;
      }
      if (_watched.isEmpty) {
        _revealFirstRow();
        return;
      }
      Scrollable.ensureVisible(
        row,
        alignment: 1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _open(TedFilmographyEntry entry) async {
    if (_opening) return;
    if (entry.media == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ['new', 'queued'].contains(entry.identityStatus)
                ? 'This title is still being identified. Try again shortly.'
                : 'This appearance could not be linked to the discovery catalogue.',
          ),
        ),
      );
      return;
    }
    final owner = _artwork, client = widget.client;
    setState(() => _opening = true);
    try {
      final title = await client.title(entry.media!);
      if (mounted && identical(owner, _artwork) && owner.valid) widget.onOpen(title);
    } catch (_) {
      if (mounted && identical(owner, _artwork) && owner.valid) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('This title could not be opened. Try again.')));
      }
    } finally {
      if (mounted && identical(owner, _artwork)) setState(() => _opening = false);
    }
  }

  MediaItem _item(TedFilmographyEntry entry) => MediaItem.ted(
    id: entry.id,
    serverId: TedPresentation(widget.client).scope,
    serverName: 'TED',
    kind: entry.type == 'Movie' ? MediaKind.movie : MediaKind.show,
    title: entry.name,
    summary: entry.overview,
    year: entry.year,
    // A watched episode is not proof that every episode of a show is complete.
    viewCount: entry.type == 'Movie' && entry.watched == true ? 1 : 0,
    leafCount: entry.episodeCount,
    viewedLeafCount: entry.watchedEpisodeCount,
    raw: {
      'watchlist': entry.watchlist,
      'user_rating': entry.userRating,
      'user_watches': entry.userWatches.map((w) => w.toJson()).toList(),
      'joint_watches': entry.jointWatches.map((w) => w.toJson()).toList(),
    },
  );
  Widget _row(bool watched, double maxWidth) {
    final entries = watched ? _watched : _other;
    final firstRow = watched || _watched.isEmpty;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: (widget.horizontalInset - 3).clamp(0, double.infinity)),
      child: HubSection(
        key: watched ? _watchedKey : _otherKey,
        showUnviewedCount: watched,
        hub: MediaHub(
          id: 'person-${widget.person.id}-${watched ? 'watched' : 'other'}',
          title: watched ? 'Watched' : 'Other appearances',
          type: 'mixed',
          items: entries.map(_item).toList(),
          serverId: TedPresentation(widget.client).scope,
        ),
        focusMemory: _memory,
        icon: watched ? Icons.history : Icons.movie_outlined,
        inset: true,
        cardSizing: HubCardSizing.grid,
        maxCardWidth: maxWidth,
        autoScroll: !firstRow,
        focusScrollAlignment: watched ? .45 : 1,
        onFocusedItemChanged: (_) {
          _lastLane = watched ? 'watched' : 'other';
          if (firstRow) _revealFirstRow();
        },
        onItemTap: (item) => unawaited(_open(entries.firstWhere((v) => v.id == item.id))),
        onItemLongPress: (_) {},
        onNavigateToSidebar: widget.onSidebar,
        onBack: widget.onClose,
        onVerticalNavigation: (up) {
          if (up) {
            if (watched || _watched.isEmpty) {
              _focusBiography();
            } else {
              _focusRow(true);
            }
          } else if (watched && _other.isNotEmpty) {
            _focusRow(false);
          }
          return true;
        },
        captionBuilder: (context, item) {
          final entry = entries.firstWhere((v) => v.id == item.id);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, height: 1.1),
              ),
              Text(
                tedEnglishCharacterNames(entry.roles),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11, height: 1.1),
              ),
            ],
          );
        },
        artworkBuilder: (context, item, width, height) {
          final entry = entries.firstWhere((v) => v.id == item.id);
          final primary = entry.images.where((v) => v.type == 'Primary').firstOrNull;
          final character = entry.images.where((v) => v.type == 'Thumb').firstOrNull;
          return _PrivateArtwork(
            artwork: _artwork,
            id: character?.id ?? primary?.id,
            width: width,
            height: height,
            label: entry.name,
            fallback: _PrivateArtwork(
              artwork: _artwork,
              id: character == null ? null : primary?.id,
              width: width,
              height: height,
              label: entry.name,
              fallback: Center(child: Icon(entry.type == 'Movie' ? Icons.movie_outlined : Icons.tv, size: 36)),
            ),
          );
        },
      ),
    );
  }

  void _biography() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_person?.name ?? widget.person.name),
        content: SizedBox(width: 620, child: SingleChildScrollView(child: Text(_person!.overview))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  static String _date(DateTime date) => '${date.day}/${date.month}/${date.year}';
  List<String> _facts() {
    final person = _person;
    if (person == null) return [];
    final birthday = person.premiereDate, death = person.endDate;
    final now = death ?? DateTime.now();
    final age = birthday == null
        ? null
        : now.year -
              birthday.year -
              (now.month < birthday.month || now.month == birthday.month && now.day < birthday.day ? 1 : 0);
    return [
      if (birthday != null)
        'Born ${_date(birthday)}${age != null && age >= 0 ? ' · ${death == null ? 'Age' : 'Aged'} $age' : ''}',
      if (death != null) 'Died ${_date(death)}',
      if (person.productionLocations.isNotEmpty) person.productionLocations.join(' · '),
    ];
  }

  Widget _banner(double height, double width) {
    final originMeta = widget.originMetadata ?? widget.origin.enrichment;
    final backdrop = originMeta?.images.where((v) => v.type == 'Backdrop').firstOrNull;
    final facts = _facts();
    final narrow = width < 650;
    final portraitHeight = narrow ? 168.0 : (height - 138).clamp(168.0, 303.0);
    final portrait = ClipRRect(
      key: const ValueKey('person-portrait'),
      borderRadius: BorderRadius.circular(12),
      child: _PrivateArtwork(
        artwork: _artwork,
        id: widget.person.id,
        person: true,
        label: widget.person.name,
        width: portraitHeight * .70,
        height: portraitHeight,
        fallback: const Center(child: Icon(Icons.person, size: 64)),
      ),
    );
    final details = Column(
      key: const ValueKey('person-facts'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _person?.name.isNotEmpty == true ? _person!.name : widget.person.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (tedEnglishCharacterNames([widget.person.role]).isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            tedEnglishCharacterNames([widget.person.role]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final fact in facts)
            Text(fact, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
    final biography = _person?.overview ?? '';
    final controls = TedFocusRegion(
      key: _controls,
      scroll: false,
      onUp: widget.onHeader,
      onDown: () => _focusRow(_watched.isNotEmpty),
      onLeft: widget.onSidebar,
      onBack: widget.onClose,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focus) {
          if (focus) {
            _lastLane = 'controls';
            _revealFirstRow();
          }
        },
        child: LayoutBuilder(
          builder: (context, box) {
            final style = Theme.of(context).textTheme.bodyMedium;
            final lines = narrow
                ? 3
                : width < 750
                ? 4
                : 8;
            final painter = TextPainter(
              text: TextSpan(text: biography, style: style),
              maxLines: lines,
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(maxWidth: box.maxWidth);
            final truncated = painter.didExceedMaxLines;
            painter.dispose();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (biography.isNotEmpty) ...[
                  Text(
                    biography,
                    maxLines: lines,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (truncated) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(focusNode: _readMore, onPressed: _biography, child: const Text('Read more')),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
    return SizedBox(
      key: const ValueKey('person-banner'),
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _PrivateArtwork(
            artwork: _artwork,
            id: backdrop?.id,
            label: widget.origin.name,
            width: width,
            height: height,
            fallback: CyclingMediaBackdrop(
              mediaKey: widget.origin.media,
              imagePaths: [if (widget.origin.background.isNotEmpty) widget.origin.background],
              fallbackImagePaths: [if (widget.origin.poster.isNotEmpty) widget.origin.poster],
              client: null,
              width: width,
              height: height,
              fallbackColor: Theme.of(context).scaffoldBackgroundColor,
              active: false,
            ),
          ),
          const DecoratedBox(decoration: BoxDecoration(color: Color(0x88000000))),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Theme.of(context).scaffoldBackgroundColor],
                stops: const [.55, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(widget.horizontalInset, 64, widget.horizontalInset, 20),
            child: narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          portrait,
                          const SizedBox(width: 16),
                          Expanded(child: details),
                        ],
                      ),
                      const SizedBox(height: 16),
                      controls,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      portrait,
                      const SizedBox(width: 24),
                      SizedBox(width: (width * .25).clamp(200.0, 320.0), child: details),
                      const SizedBox(width: 20),
                      Expanded(child: controls),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final narrow = box.maxWidth < 600;
      final compactHeight = narrow ? 340.0 : (box.maxHeight * .28).clamp(230.0, 310.0);
      final bannerHeight = compactHeight * 1.5;
      // Retain the existing cards while giving the banner more space. The
      // second shelf can extend below the viewport and scroll into view.
      final rowBudget = (box.maxHeight - compactHeight - 40) / 2;
      final width = ((rowBudget - (PlatformDetector.isTV() ? 106 : 76)) / 1.5 + 6).clamp(100.0, 180.0);
      return SingleChildScrollView(
        controller: _scroll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _banner(bannerHeight, box.maxWidth),
            SizedBox(height: 3, child: _busy || _opening ? const LinearProgressIndicator() : null),
            if (_error != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset),
                child: TedFocusRegion(
                  onUp: _focusControls,
                  onDown: requestFocus,
                  onLeft: widget.onSidebar,
                  onBack: widget.onClose,
                  child: Row(
                    children: [
                      Expanded(child: Text(_error!, style: Theme.of(context).textTheme.bodySmall)),
                      TextButton(onPressed: _busy ? null : reload, child: const Text('Retry')),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            if (_watched.isNotEmpty) _row(true, width),
            if (_watched.isNotEmpty && _other.isNotEmpty)
              const SizedBox(height: 12 * ContentLayoutConstants.rowGapScale),
            if (_other.isNotEmpty) _row(false, width),
            if (_entries.any((v) => v.viewed == null))
              Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset, vertical: 4),
                child: Text(
                  'Some appearances are still being identified; their watch status is unknown.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// One page-scoped authenticated artwork owner, coalesced and limited to five
/// concurrent workflows. Private bytes stay out of shared public disk caches.
class _PersonArtwork {
  final TedClient client;
  final (Uri?, int?) _scope;
  final _cache = <(String, bool), Uint8List?>{};
  final _pending = <(String, bool), Completer<Uint8List?>>{};
  final _queue = Queue<(String, bool)>();
  int _active = 0, _bytes = 0;
  bool _disposed = false;
  _PersonArtwork(this.client) : _scope = (client.auth.server, client.auth.userId);
  bool get valid => !_disposed && _scope == (client.auth.server, client.auth.userId);
  Future<Uint8List?> load(String id, bool person) {
    final key = (id, person);
    if (!valid) return Future.value();
    if (_cache.containsKey(key)) return Future.value(_cache[key]);
    if (_pending.containsKey(key)) return _pending[key]!.future;
    final completion = Completer<Uint8List?>();
    _pending[key] = completion;
    _queue.add(key);
    _pump();
    return completion.future;
  }

  void _pump() {
    while (valid && _active < 5 && _queue.isNotEmpty) {
      _active++;
      unawaited(_run(_queue.removeFirst()));
    }
  }

  Future<void> _run((String, bool) key) async {
    Uint8List? bytes;
    try {
      for (var i = 0; valid && i < 12; i++) {
        bytes = key.$2 ? await client.personPortrait(key.$1) : await client.metadataImage(key.$1);
        if (bytes != null || !valid) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } catch (_) {
      /* Existing backdrop/person icon remains usable. */
    } finally {
      if (valid) {
        _cache[key] = bytes;
        _bytes += bytes?.length ?? 0;
        while (_cache.length > 64 || _bytes > 20 * 1024 * 1024) {
          _bytes -= _cache.remove(_cache.keys.first)?.length ?? 0;
        }
      }
      _pending.remove(key)?.complete(valid ? bytes : null);
      _active--;
      _pump();
    }
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
    _queue.clear();
    for (final value in _pending.values) {
      value.complete(null);
    }
    _pending.clear();
  }
}

class _PrivateArtwork extends StatefulWidget {
  final _PersonArtwork artwork;
  final String? id;
  final bool person;
  final double? width, height;
  final String label;
  final Widget fallback;
  const _PrivateArtwork({
    required this.artwork,
    this.id,
    this.person = false,
    this.width,
    this.height,
    required this.label,
    required this.fallback,
  });
  @override
  State<_PrivateArtwork> createState() => _PrivateArtworkState();
}

class _PrivateArtworkState extends State<_PrivateArtwork> {
  Uint8List? _bytes;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PrivateArtwork old) {
    super.didUpdateWidget(old);
    if (old.artwork != widget.artwork || old.id != widget.id || old.person != widget.person) {
      _bytes = null;
      _load();
    }
  }

  void _load() {
    final generation = ++_generation, owner = widget.artwork;
    if (widget.id == null) return;
    unawaited(
      owner.load(widget.id!, widget.person).then((bytes) {
        if (mounted && generation == _generation && owner.valid) setState(() => _bytes = bytes);
      }),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: _bytes == null
        ? widget.fallback
        : Image(
            image: MediaImageHelper.boundedDecode(
              MemoryImage(_bytes!),
              memWidth: ((widget.width ?? 180) * MediaQuery.devicePixelRatioOf(context)).round(),
              memHeight: ((widget.height ?? 270) * MediaQuery.devicePixelRatioOf(context)).round(),
            ),
            fit: BoxFit.cover,
            semanticLabel: widget.label,
            errorBuilder: (_, _, _) => widget.fallback,
          ),
  );
}
