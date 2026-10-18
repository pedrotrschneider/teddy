import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/cycling_media_backdrop.dart';
import '../widgets/fitting_title_text.dart';
import '../widgets/optimized_media_image.dart';
import '../utils/tone_mapped_logo_image.dart';
import '../utils/platform_detector.dart';
import 'ted_client.dart';
import 'ted_dates.dart';
import 'ted_metadata_models.dart';
import 'ted_models.dart';
import 'ted_focus_region.dart';
import 'ted_play_button.dart';
import 'ted_spoiler.dart';

class TedHomeBanner extends StatefulWidget {
  final TedClient client;
  final List<TedTitle> entries;
  final int refreshEpoch;
  final double? maxHeight;
  final double? contentHorizontalInset;

  /// Static passive layout, shared by catalogue spotlights and detail headers.
  final bool catalogPreview;
  final bool debounceEnrichment;
  final bool loadDetails;

  /// Catalogue focus uses Cinemeta summaries only. Disable all provider detail,
  /// polling and image work, including enrichment already attached to a title.
  final bool enrichMetadata;

  /// Detail pages keep the shared backdrop/logo while adding season or
  /// episode artwork to the left of its normal text block.
  final Widget? leadingArtwork;
  final double leadingAspectRatio;
  final String? detailHeading, descriptionOverride;
  final bool hideEpisodeDescription;
  final bool showReleaseDate;
  final DateTime? releaseDate;
  final Future<void> Function(TedTitle) onPlay, onOpen;
  final VoidCallback onBack;
  final VoidCallback? onNavigateUp, onNavigateDown;
  final void Function(TedMediaIdentity media, TedMetadataSnapshot snapshot)? onMetadata;
  const TedHomeBanner({
    super.key,
    required this.client,
    required this.entries,
    required this.refreshEpoch,
    this.maxHeight,
    this.contentHorizontalInset,
    this.catalogPreview = false,
    this.debounceEnrichment = true,
    this.loadDetails = true,
    this.enrichMetadata = true,
    this.leadingArtwork,
    this.leadingAspectRatio = 2 / 3,
    this.detailHeading,
    this.descriptionOverride,
    this.hideEpisodeDescription = false,
    this.showReleaseDate = false,
    this.releaseDate,
    required this.onPlay,
    required this.onOpen,
    required this.onBack,
    this.onNavigateUp,
    this.onNavigateDown,
    this.onMetadata,
  });
  @override
  State<TedHomeBanner> createState() => TedHomeBannerState();
}

class _BannerSlide {
  final TedTitle title;
  TedTitle? visual;
  TedMetadataSnapshot? metadata;
  Uint8List? backdrop, logo;
  bool loading = true;
  String? notice;
  _BannerSlide(this.title);
  String get name => metadata?.name.isNotEmpty == true
      ? metadata!.name
      : visual?.name ?? (title.seriesName.isNotEmpty ? title.seriesName : title.name);
  String get description =>
      metadata?.overview.isNotEmpty == true ? metadata!.overview : visual?.description ?? title.description;
}

class TedHomeBannerState extends State<TedHomeBanner> with WidgetsBindingObserver {
  static const _advanceDuration = Duration(seconds: 5);
  static const _indicatorInterval = Duration(milliseconds: 50);
  final _pages = PageController();
  final _focus = FocusNode(debugLabel: 'ted_home_banner');
  final _actions = GlobalKey<TedFocusRegionState>();
  final _controls = GlobalKey<TedFocusRegionState>();

  bool requestFocus() => !PlatformDetector.isTV() && (_actions.currentState?.requestFocus(first: true) ?? false);
  bool requestFocusFromMemory() => !PlatformDetector.isTV() && (_actions.currentState?.requestFocus() ?? false);
  bool get controlsHaveFocus => _controls.currentState?.hasFocus ?? false;
  bool requestControlsFocus() => !PlatformDetector.isTV() && (_controls.currentState?.requestFocus() ?? requestFocus());
  final _indicatorProgress = ValueNotifier<double>(1);
  Timer? _timer;
  Timer? _enrichmentTimer;
  List<_BannerSlide> _slides = [];
  int _index = 0, _generation = 0;
  TedClient? _owner;
  (Uri?, int?)? _scope;
  bool _paused = false, _resumed = true, _playing = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _replace();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(TedHomeBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.catalogPreview != widget.catalogPreview ||
        oldWidget.enrichMetadata != widget.enrichMetadata ||
        oldWidget.refreshEpoch != widget.refreshEpoch ||
        !listEquals(oldWidget.entries, widget.entries) ||
        _scope != (widget.client.auth.server, widget.client.auth.userId)) {
      _replace();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _schedule();
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _enrichmentTimer?.cancel();
    _indicatorProgress.dispose();
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _replace() {
    _enrichmentTimer?.cancel();
    final scope = (widget.client.auth.server, widget.client.auth.userId);
    final current = _slides.isEmpty ? null : _slides[_index].title.media;
    final old = widget.client == _owner && scope == _scope
        ? {for (final slide in _slides) slide.title.media: slide}
        : <TedMediaIdentity, _BannerSlide>{};
    _owner = widget.client;
    _scope = scope;
    _slides = [
      for (final title in widget.entries)
        if (!widget.enrichMetadata)
          _BannerSlide(title)..loading = false
        else
          _BannerSlide(title)
            ..visual = old[title.media]?.visual
            ..metadata = title.enrichment ?? old[title.media]?.metadata
            ..backdrop = old[title.media]?.backdrop
            ..logo = old[title.media]?.logo,
    ];
    _index = math.max(0, _slides.indexWhere((s) => s.title.media == current));
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_valid(generation, scope)) return;
      if (_pages.hasClients) _pages.jumpToPage(_index);
      _schedule();
      if (!widget.enrichMetadata) return;
      if (widget.catalogPreview && widget.debounceEnrichment && _slides.any((s) => s.metadata == null)) {
        _enrichmentTimer = Timer(const Duration(milliseconds: 100), () {
          if (_valid(generation, scope) && ModalRoute.of(context)?.isCurrent != false) {
            unawaited(_enrich(generation, scope));
          }
        });
      } else {
        unawaited(_enrich(generation, scope));
      }
    });
  }

  bool _valid(int generation, (Uri?, int?) scope) =>
      mounted && generation == _generation && scope == (widget.client.auth.server, widget.client.auth.userId);
  Future<void> _enrich(int generation, (Uri?, int?) scope) async {
    final slides = _slides;
    int next = 0;
    // Bound concurrent detail/image work, independently of the carousel index.
    await Future.wait(
      List.generate(2, (_) async {
        while (_valid(generation, scope) && next < slides.length) {
          final slide = slides[next++];
          try {
            final identity = slide.title.media.kind == 'episode'
                ? slide.title.parent ?? TedMediaIdentity('series', slide.title.media.id.split(':').first)
                : slide.title.media;
            final visual = !widget.loadDetails || slide.title.enrichment != null && !slide.title.enrichment!.unavailable
                ? slide.title
                : await widget.client.title(identity);
            if (!_valid(generation, scope)) return;
            setState(() {
              slide.visual = visual;
              slide.metadata = visual.enrichment;
            });
            var snapshot = visual.enrichment;
            if (snapshot != null) widget.onMetadata?.call(identity, snapshot);
            for (var attempt = 0; snapshot?.pending == true && attempt < 20; attempt++) {
              await Future<void>.delayed(const Duration(seconds: 1));
              if (!_valid(generation, scope)) return;
              snapshot = await widget.client.metadata(snapshot!.id);
              if (!_valid(generation, scope)) return;
              setState(() => slide.metadata = snapshot);
              widget.onMetadata?.call(identity, snapshot);
            }
            if (snapshot != null) {
              if (snapshot.pending || snapshot.unavailable) {
                slide.notice = snapshot.status == 'not_configured'
                    ? 'Configure metadata providers in TED to load more artwork.'
                    : 'Metadata is incomplete. Retry to check for updates.';
              }
              final backdrop =
                  snapshot.images.where((a) => a.type == 'Backdrop').firstOrNull ??
                  snapshot.images.where((a) => a.type == 'Primary').firstOrNull;
              final logo = snapshot.images.where((a) => a.type == 'Logo').firstOrNull;
              for (final asset in [backdrop, logo]) {
                if (asset == null) continue;
                Uint8List? bytes;
                for (var attempt = 0; attempt < 12; attempt++) {
                  if (!_valid(generation, scope)) return;
                  try {
                    bytes = await widget.client.metadataImage(asset.id);
                  } on TedFailure {
                    slide.notice = 'Some artwork is unavailable. Retry to load it.';
                    break;
                  }
                  if (!_valid(generation, scope)) return;
                  if (bytes != null) break;
                  await Future<void>.delayed(const Duration(seconds: 1));
                }
                if (!_valid(generation, scope)) return;
                if (bytes == null) {
                  slide.notice ??= 'Artwork is still loading. Retry to check for updates.';
                  continue;
                }
                setState(() {
                  if (asset == backdrop) {
                    slide.backdrop = bytes;
                  } else {
                    slide.logo = bytes;
                  }
                });
              }
            }
          } on TedFailure catch (error) {
            if (!_valid(generation, scope)) return;
            slide.notice = error.code == 'sign_in_required'
                ? error.message
                : 'Metadata is unavailable. Retry to load it.';
          } catch (_) {
            if (!_valid(generation, scope)) return;
            slide.notice = 'Metadata is unavailable. Retry to load it.';
          } finally {
            if (_valid(generation, scope)) setState(() => slide.loading = false);
          }
        }
      }),
    );
  }

  void _schedule() {
    _timer?.cancel();
    _indicatorProgress.value = 1;
    if (!mounted ||
        _slides.length < 2 ||
        _paused ||
        !_resumed ||
        _playing ||
        !TickerMode.valuesOf(context).enabled ||
        MediaQuery.maybeOf(context)?.disableAnimations == true) {
      return;
    }
    _indicatorProgress.value = 0;
    // Plezy's Discover pill uses a small ValueNotifier-driven fill. One clock
    // drives both this fill and advancement so they cannot drift apart.
    _timer = Timer.periodic(_indicatorInterval, (timer) {
      final progress = (timer.tick * _indicatorInterval.inMilliseconds / _advanceDuration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      _indicatorProgress.value = progress;
      if (progress < 1) return;
      timer.cancel();
      if (mounted && _pages.hasClients && ModalRoute.of(context)?.isCurrent != false) {
        _go((_index + 1) % _slides.length);
      } else {
        _schedule();
      }
    });
  }

  void _go(int index) {
    if (_slides.isEmpty || !_pages.hasClients) return;
    _pages.animateToPage(
      (index + _slides.length) % _slides.length,
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _activate(_BannerSlide slide, {bool details = false}) async {
    if (_playing) return;
    final restoreAction = _actions.currentState?.hasFocus ?? false;
    setState(() => _playing = true);
    _schedule();
    try {
      await (details || !slide.title.media.playable ? widget.onOpen(slide.title) : widget.onPlay(slide.title));
    } finally {
      if (mounted) {
        setState(() => _playing = false);
        _schedule();
        if (restoreAction) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                ModalRoute.of(context)?.isCurrent != false &&
                FocusManager.instance.primaryFocus is FocusScopeNode) {
              requestFocus();
            }
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_slides.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        final theme = Theme.of(context);
        final passive = widget.catalogPreview || PlatformDetector.isTV();
        final wide = box.maxWidth >= 760;
        // Very short windows scroll instead of crushing the controls.
        final height = widget.catalogPreview && box.hasBoundedHeight
            ? box.maxHeight
            : widget.maxHeight != null
            ? math.min(MediaQuery.sizeOf(context).height * .64, widget.maxHeight!).clamp(300.0, 740.0)
            : wide
            ? (MediaQuery.sizeOf(context).height * .64).clamp(360.0, 740.0)
            : math.min(500.0, math.max(box.maxWidth < 420 ? 480.0 : 360.0, MediaQuery.sizeOf(context).height * .75));
        return Focus(
          focusNode: _focus,
          skipTraversal: true,
          canRequestFocus: !passive,
          descendantsAreFocusable: !passive,
          descendantsAreTraversable: !passive,
          onKeyEvent: (_, event) {
            if (passive || !_focus.hasPrimaryFocus || event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              widget.onNavigateUp?.call();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.select) {
              unawaited(_activate(_slides[_index]));
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              if (_index == 0) {
                widget.onBack();
              } else {
                _go(_index - 1);
              }
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _go(_index + 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.goBack) {
              widget.onBack();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: IgnorePointer(
            ignoring: passive,
            child: SizedBox(
              height: height,
              child: Stack(
                children: [
                  PageView.builder(
                    controller: _pages,
                    itemCount: _slides.length,
                    onPageChanged: (i) {
                      if (i < 0 || i >= _slides.length) return;
                      setState(() => _index = i);
                      _schedule();
                    },
                    itemBuilder: (context, i) => _backdrop(_slides[i], box.maxWidth, height, i == _index),
                  ),
                  Positioned(
                    left: widget.contentHorizontalInset ?? (wide ? 40 : 24),
                    right: widget.contentHorizontalInset ?? 24,
                    bottom: widget.catalogPreview ? 24 : 66,
                    child: widget.leadingArtwork == null
                        ? _foreground(_slides[_index], box.maxWidth, height, wide)
                        : _detailForeground(_slides[_index], box.maxWidth, height, wide),
                  ),
                  if (!widget.catalogPreview)
                    Positioned(
                      bottom: 10,
                      left: 0,
                      right: 0,
                      child: TedFocusRegion(
                        key: _controls,
                        scroll: false,
                        onUp: requestFocus,
                        onDown: widget.onNavigateDown,
                        onLeft: widget.onBack,
                        onBack: widget.onBack,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              tooltip: 'Previous banner',
                              onPressed: _slides.length < 2 ? null : () => _go(_index - 1),
                              icon: const Icon(Icons.chevron_left),
                            ),
                            IconButton(
                              tooltip: _paused ? 'Resume carousel' : 'Pause carousel',
                              onPressed: () {
                                setState(() => _paused = !_paused);
                                _schedule();
                              },
                              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                            ),
                            for (var i = 0; i < _slides.length; i++)
                              Semantics(
                                selected: i == _index,
                                child: IconButton(
                                  tooltip: 'Banner ${i + 1} of ${_slides.length}',
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(32, 40),
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => _go(i),
                                  icon: i == _index
                                      ? ValueListenableBuilder<double>(
                                          valueListenable: _indicatorProgress,
                                          builder: (context, progress, _) => Container(
                                            key: ValueKey('banner-indicator-$i'),
                                            width: 24,
                                            height: 8,
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.onSurface.withValues(alpha: .4),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: Container(
                                                key: ValueKey('banner-progress-$i'),
                                                width: 8 + 16 * progress,
                                                height: 8,
                                                decoration: BoxDecoration(
                                                  color: theme.colorScheme.onSurface,
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                              ),
                                            ),
                                          ),
                                        )
                                      : AnimatedContainer(
                                          duration: const Duration(milliseconds: 180),
                                          width: 8,
                                          height: 8,
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.onSurface.withValues(alpha: .4),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                        ),
                                ),
                              ),
                            IconButton(
                              tooltip: 'Next banner',
                              onPressed: _slides.length < 2 ? null : () => _go(_index + 1),
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _backdrop(_BannerSlide slide, double width, double height, bool active) {
    final theme = Theme.of(context), title = slide.title, visual = slide.visual ?? slide.title;
    final background = 'ted-banner/${slide.metadata?.id}/${slide.metadata?.generation}';
    final art = [if (slide.backdrop != null) background else if (visual.background.isNotEmpty) visual.background];
    return IgnorePointer(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white,
            Colors.white,
            Color(0xE6FFFFFF),
            Color(0x8CFFFFFF),
            Color(0x26FFFFFF),
            Colors.transparent,
          ],
          stops: [0, .2, .4, .65, .85, 1],
        ).createShader(bounds),
        child: CyclingMediaBackdrop(
          mediaKey: title.media,
          imagePaths: art,
          fallbackImagePaths: [visual.background, visual.poster],
          client: null,
          width: width,
          height: height,
          fallbackColor: theme.colorScheme.surfaceContainerHighest,
          active: active,
          // The shared path provides disk caching, request admission and
          // two-axis, device-aware decode bounds for Cinemeta backdrops (or
          // tall poster fallbacks). A width-only 1920 decode bypasses those.
          imageProviderResolver: !widget.enrichMetadata
              ? null
              : (path) => ResizeImage.resizeIfNeeded(
                  1920,
                  null,
                  path == background && slide.backdrop != null ? MemoryImage(slide.backdrop!) : NetworkImage(path),
                ),
        ),
      ),
    );
  }

  Widget _foreground(_BannerSlide slide, double width, double height, bool wide) {
    final theme = Theme.of(context), title = slide.title, visual = slide.visual ?? slide.title;
    final light = theme.brightness == Brightness.light;
    final foreground = light ? theme.colorScheme.onSurface : Colors.white;
    final compact = height < 340;
    final logoWidth = math.min(wide ? 380.0 : 280.0, width - 48);
    final logoHeight = compact
        ? 36.0
        : height < 450
        ? 72.0
        : wide
        ? 120.0
        : 80.0;
    Widget fallback(BuildContext context) => FittingTitleText(
      slide.name,
      style: theme.textTheme.displaySmall?.copyWith(
        color: foreground,
        fontWeight: FontWeight.bold,
        shadows: const [Shadow(blurRadius: 8)],
      ),
    );
    final year = slide.metadata?.year?.toString() ?? visual.year;
    final rating = slide.metadata?.rating ?? visual.rating;
    final description = widget.descriptionOverride ?? slide.description;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 740),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: wide ? math.min(600, width - 80) : width - 48,
            height: logoHeight,
            child: slide.logo == null
                ? ClearLogoImage(
                    client: null,
                    logoPath: visual.logo,
                    width: logoWidth,
                    height: logoHeight,
                    fallbackWidth: wide ? math.min(600, width - 80) : width - 48,
                    fallbackBuilder: fallback,
                    logoToneTarget: light ? foreground : null,
                  )
                : Align(
                    alignment: Alignment.bottomLeft,
                    child: Image(
                      image: light
                          ? ToneMappedLogoImage(
                              ResizeImage.resizeIfNeeded(1200, null, MemoryImage(slide.logo!)),
                              target: foreground,
                              remapMixed: false,
                            )
                          : MemoryImage(slide.logo!),
                      width: logoWidth,
                      height: logoHeight,
                      fit: BoxFit.contain,
                      alignment: Alignment.bottomLeft,
                      errorBuilder: (context, _, _) => fallback(context),
                    ),
                  ),
          ),
          SizedBox(height: compact ? 8 : 16),
          Text(
            [
              title.media.kind == 'movie' ? 'Movie' : 'Series',
              if (rating != null) '★ ${rating.toStringAsFixed(1)}',
              if (year.isNotEmpty) year,
              if (slide.metadata?.certification?.isNotEmpty == true) slide.metadata!.certification!,
            ].join(' • '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(color: foreground),
          ),
          if (title.media.kind == 'episode') ...[
            SizedBox(height: compact ? 8 : 12),
            Text(
              'S${title.season ?? "?"}, E${title.episode ?? "?"}: ${title.episodeName.isEmpty ? title.name : title.episodeName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(color: foreground.withValues(alpha: .85)),
            ),
          ],
          if (widget.detailHeading != null) ...[
            const SizedBox(height: 12),
            Text(
              widget.detailHeading!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(color: foreground),
            ),
          ],
          if (widget.showReleaseDate) ...[
            const SizedBox(height: 8),
            Text(
              tedReleaseDate(
                widget.releaseDate ??
                    (widget.detailHeading == null ? slide.metadata?.premiereDate ?? title.releaseDate : null),
              ),
              style: theme.textTheme.bodyMedium?.copyWith(color: foreground.withValues(alpha: .85)),
            ),
          ],
          if (description.isNotEmpty && (height >= 450 || widget.catalogPreview && height >= 280)) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: wide ? math.min(640, width - 80) : width - 48,
              child: TedSpoiler(
                unwatchedEpisode:
                    widget.hideEpisodeDescription || (slide.title.media.kind == 'episode' && !slide.title.played),
                child: Text(
                  description,
                  maxLines: wide ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(color: foreground.withValues(alpha: .85)),
                ),
              ),
            ),
          ],
          if (!widget.catalogPreview) ...[
            SizedBox(height: compact ? 12 : 20),
            TedFocusRegion(
              key: _actions,
              onUp: widget.onNavigateUp,
              onDown: requestControlsFocus,
              onLeft: widget.onBack,
              onBack: widget.onBack,
              child: _actionButtons(slide, height),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailForeground(_BannerSlide slide, double width, double height, bool wide) {
    final inset = widget.contentHorizontalInset ?? (wide ? 40.0 : 24.0);
    final available = math.max(0.0, width - inset * 2);
    final artWidth = math.min(
      math.min(widget.leadingAspectRatio > 1 ? 540.0 : 340.0, available * (wide ? .45 : .30)),
      math.max(0.0, height - 112) * widget.leadingAspectRatio,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          key: const ValueKey('ted-detail-leading-artwork'),
          width: artWidth,
          height: artWidth / widget.leadingAspectRatio,
          child: ClipRRect(borderRadius: BorderRadius.circular(8), child: widget.leadingArtwork!),
        ),
        SizedBox(width: wide ? 28 : 16),
        Expanded(child: _foreground(slide, math.max(64, available - artWidth - (wide ? 28 : 16)), height, wide)),
      ],
    );
  }

  Widget _actionButtons(_BannerSlide slide, double height) {
    final theme = Theme.of(context), title = slide.title;
    final light = theme.brightness == Brightness.light;
    final foreground = light ? theme.colorScheme.onSurface : Colors.white;
    final compact = height < 340;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TedPlayButton(title: title, compact: compact, onPressed: _playing ? null : () => unawaited(_activate(slide))),
        if (title.media.playable)
          OutlinedButton(
            onPressed: _playing ? null : () => unawaited(_activate(slide, details: true)),
            style: OutlinedButton.styleFrom(
              foregroundColor: foreground,
              side: BorderSide(color: foreground.withValues(alpha: .54)),
              minimumSize: Size(100, compact ? 44 : 52),
            ),
            child: const Text('Details'),
          ),
        if (slide.loading)
          Tooltip(
            message: 'Loading metadata',
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: foreground)),
          )
        else if (slide.notice != null)
          IconButton(
            tooltip: slide.notice,
            onPressed: () {
              setState(_replace);
            },
            icon: Icon(Icons.refresh, color: foreground),
          ),
      ],
    );
  }
}
