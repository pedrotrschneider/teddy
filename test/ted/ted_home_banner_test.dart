import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/services/image_cache_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_home_banner.dart';
import 'package:plezy/ted/ted_browse_header.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:plezy/utils/tone_mapped_logo_image.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/io_fakes.dart' show FakePathProvider;
import 'ted_catalog_test.dart' show CatalogFixture, titleData;
import 'ted_metadata_client_test.dart' show metadataData, assetId;

final pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
TedTitle bannerTitle(int n, {String kind = 'movie', bool enrichment = true, String status = 'ready'}) =>
    TedTitle.fromJson({
      ...titleData(kind: kind, id: 'tt${1234500 + n}'),
      'metadata': {'name': 'Fallback $n', 'year': '2026', 'description': 'Saved Cinemeta description.'},
      if (enrichment)
        'enrichment': {
          ...metadataData(status: status),
          'item': {
            'Id': metadataData()['item']['Id'],
            'Type': kind == 'series' ? 'Series' : 'Movie',
            'Name': status == 'queued' ? 'Fallback $n' : 'Enriched $n',
            'Overview': 'Provider description for the selected title.',
            'CommunityRating': 8.6,
            'ProductionYear': 2026,
          },
        },
    });

class BannerFixture extends CatalogFixture {
  final requests = <TedMediaIdentity>[];
  final held = <TedMediaIdentity, Completer<TedTitle>>{};
  bool pending = false, images = false;
  int polls = 0, imageRequests = 0;
  @override
  Future<TedTitle> title(TedMediaIdentity media) async {
    requests.add(media);
    if (held.containsKey(media)) return held[media]!.future;
    final n = int.parse(media.id.substring(2)) - 1234500;
    final data = bannerTitle(n, kind: media.kind, status: pending ? 'queued' : 'ready');
    if (!images) return data;
    return TedTitle(
      data.media,
      data.name,
      data.description,
      data.played,
      data.revision,
      data.positionMs,
      data.local,
      ready: data.ready,
      enrichment: TedMetadataSnapshot.fromJson({
        ...metadataData(status: pending ? 'queued' : 'ready', images: true),
        if (pending)
          'item': <String, dynamic>{
            ...metadataData()['item'] as Map<String, dynamic>,
            'Name': data.name,
            'Overview': data.description,
          },
      }),
    );
  }

  @override
  Future<TedMetadataSnapshot> metadata(String id) async {
    polls++;
    return TedMetadataSnapshot.fromJson(metadataData(images: images));
  }

  @override
  Future<Uint8List?> metadataImage(String id) async {
    expect(id, assetId);
    imageRequests++;
    return imageRequests == 1 ? null : pixel;
  }
}

/// Optional visual evidence uses saved actual native DTOs and provider bytes;
/// credentials/network access are never needed by the rendering test.
class LiveBannerFixture extends BannerFixture {
  final details = <TedMediaIdentity, TedTitle>{};
  final snapshots = <String, TedMetadataSnapshot>{};
  final artwork = <String, Uint8List>{};
  final logos = <Uint8List>[];
  final entries = <TedTitle>[];
  LiveBannerFixture(String root) {
    final report = jsonDecode(File('$root/report.json').readAsStringSync()) as Map<String, dynamic>;
    final home = jsonDecode(File('$root/home.json').readAsStringSync()) as Map<String, dynamic>;
    final titles = [
      for (final row in home['rows'] as List)
        for (final title in row['titles'] as List) TedTitle.fromJson(title as Map<String, dynamic>),
    ];
    final records = report['records'] as List;
    for (var i = 0; i < records.length; i++) {
      final record = records[i] as Map<String, dynamic>,
          meta = jsonDecode(File('$root/metadata-$i.json').readAsStringSync()) as Map<String, dynamic>;
      final snapshot = TedMetadataSnapshot.fromJson(meta);
      snapshots[snapshot.id] = snapshot;
      final detail = jsonDecode(File('$root/detail-$i.json').readAsStringSync()) as Map<String, dynamic>;
      final title = TedTitle.fromJson({...detail, 'enrichment': meta});
      details[title.media] = title;
      final identity = TedMediaIdentity.fromJson(record['media'] as Map<String, dynamic>);
      entries.add(titles.firstWhere((t) => t.media == identity));
      for (final image in record['artwork'] as List) {
        if (image['status'] != 200) continue;
        final asset = snapshot.images.firstWhere((a) => a.type == image['type']);
        artwork[asset.id] = File('$root/${image['file']}').readAsBytesSync();
        if (asset.type == 'Logo') logos.add(artwork[asset.id]!);
      }
    }
  }
  @override
  Future<TedTitle> title(TedMediaIdentity media) async => details[media]!;
  @override
  Future<TedMetadataSnapshot> metadata(String id) async => snapshots[id]!;
  @override
  Future<Uint8List?> metadataImage(String id) async => artwork[id];
}

void main() {
  final originalPaths = PathProviderPlatform.instance;
  late Directory cacheDirectory;
  setUpAll(() async {
    cacheDirectory = Directory.systemTemp.createTempSync('ted-home-banner-cache-');
    PathProviderPlatform.instance = FakePathProvider(cacheDirectory);
    // Hive/filesystem initialization must finish outside widget-test FakeAsync.
    await PlexImageCacheManager.instance.getFileFromCache('ted-banner-fixture');
    // Measure responsive text/buttons with a real bundled font. Ahem gives
    // every character a square advance and creates artificial button wrapping.
    await (FontLoader('Go Noto Current')..addFont(rootBundle.load('assets/go-noto-current-regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  tearDownAll(() async {
    await PlexImageCacheManager.instance.dispose();
    PathProviderPlatform.instance = originalPaths;
    cacheDirectory.deleteSync(recursive: true);
  });
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });
  Future<void> mount(
    WidgetTester tester,
    BannerFixture client,
    List<TedTitle> entries, {
    int epoch = 0,
    Size size = const Size(1200, 900),
    bool dark = true,
    bool reducedMotion = false,
    bool catalogPreview = false,
    bool enrichMetadata = true,
    Future<void> Function(TedTitle)? play,
    VoidCallback? back,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: monoTheme(dark: dark).copyWith(
            textTheme: monoTheme(dark: dark).textTheme.apply(fontFamily: 'Go Noto Current'),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
            child: child!,
          ),
          home: RepaintBoundary(
            key: const ValueKey('banner-page-render'),
            child: Scaffold(
              // Match Home's scrollable layout: short windows scroll the banner
              // rather than imposing the viewport height on its content.
              body: Stack(
                children: [
                  SingleChildScrollView(
                    child: RepaintBoundary(
                      key: const ValueKey('banner-render'),
                      child: TedHomeBanner(
                        client: client,
                        entries: entries,
                        refreshEpoch: epoch,
                        catalogPreview: catalogPreview,
                        enrichMetadata: enrichMetadata,
                        onPlay:
                            play ??
                            (_) {
                              return Future.value();
                            },
                        onOpen: (_) async {},
                        onBack: back ?? () {},
                      ),
                    ),
                  ),
                  Positioned(top: 0, left: 0, right: 0, child: const TedBrowseHeader()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void cleanup(WidgetTester tester, BannerFixture client) {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.auth.close);
  }

  testWidgets('summary spotlight ignores attached queued enrichment; detail headers still poll and load artwork', (
    tester,
  ) async {
    final client = BannerFixture()..images = true;
    cleanup(tester, client);
    final entry = TedTitle.fromJson({
      ...titleData(),
      'metadata': {'name': 'Cinemeta title', 'description': 'Cinemeta overview'},
      'enrichment': metadataData(status: 'queued', images: true),
    });
    await mount(tester, client, [entry], catalogPreview: true, enrichMetadata: false);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Cinemeta title'), findsOneWidget);
    expect(find.text('Cinemeta overview'), findsOneWidget);
    expect(find.text('Provider title'), findsNothing);
    expect(client.requests, isEmpty);
    expect(client.polls, 0);
    expect(client.imageRequests, 0);
    // Detail headers use the same passive layout, but retain enrichment.
    await mount(tester, client, [entry], catalogPreview: true);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Provider title'), findsOneWidget);
    expect(client.polls, 1);
    expect(client.imageRequests, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached spotlight description is immediate and cached artwork starts without the dwell delay', (
    tester,
  ) async {
    final client = BannerFixture();
    cleanup(tester, client);
    final cached = TedTitle.fromJson({...titleData(), 'enrichment': metadataData(images: true)});
    await mount(tester, client, [cached], catalogPreview: true);
    expect(find.text('Provider title'), findsOneWidget);
    expect(find.text('Provider description'), findsOneWidget);
    await tester.pump();
    expect(client.requests, isEmpty);
    expect(client.imageRequests, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(client.imageRequests, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cold spotlight still fences provider requests until 100ms of unchanged selection', (tester) async {
    final client = BannerFixture();
    cleanup(tester, client);
    await mount(tester, client, [bannerTitle(1, enrichment: false)], catalogPreview: true);
    await tester.pump(const Duration(milliseconds: 50));
    expect(client.requests, isEmpty);
    await mount(tester, client, [bannerTitle(2, enrichment: false)], catalogPreview: true);
    await tester.pump(const Duration(milliseconds: 99));
    expect(client.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(client.requests.single.id, 'tt1234502');
    expect(find.text('Enriched 2'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fallback renders immediately, selected metadata/images update progressively and episodes retain their play identity',
    (tester) async {
      final client = BannerFixture()
        ..pending = true
        ..images = true;
      cleanup(tester, client);
      await mount(tester, client, [bannerTitle(1, enrichment: false)]);
      await tester.pump();
      expect(find.text('Fallback 1'), findsOneWidget);
      expect(find.byTooltip('Loading metadata'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Provider title'), findsOneWidget);
      expect(client.polls, 1);
      expect(client.imageRequests, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(client.imageRequests, 2);
      expect(find.byTooltip('Loading metadata'), findsNothing);
      expect(tester.takeException(), isNull);
      client.pending = false;
      client.images = false;
      TedTitle? played;
      final episode = TedTitle.fromJson({
        ...titleData(kind: 'episode', id: 'tt1234502:1:3'),
        'parent': {'kind': 'series', 'id': 'tt1234502'},
        'metadata': {
          'series': {'name': 'Show title'},
          'episode': {'name': 'Third episode', 'season': 1, 'number': 3},
        },
      });
      await mount(
        tester,
        client,
        [episode],
        epoch: 1,
        play: (v) async {
          played = v;
        },
      );
      await tester.pumpAndSettle();
      expect(client.requests.last, const TedMediaIdentity('series', 'tt1234502'));
      expect(find.text('S1, E3: Third episode'), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(played?.media, episode.media);
      expect(played?.positionMs, episode.positionMs);
    },
  );
  testWidgets('carousel pause, paging, keyboard and narrow layouts remain usable', (tester) async {
    final client = BannerFixture();
    cleanup(tester, client);
    var backs = 0;
    final entries = List.generate(5, (i) => bannerTitle(i + 1, enrichment: false));
    final liveRoot = Platform.environment['TED_BANNER_LIVE_EVIDENCE_DIR'];
    final live = liveRoot == null ? null : LiveBannerFixture(liveRoot);
    if (live != null) addTearDown(live.auth.close);
    for (final size in const [Size(1200, 900), Size(320, 640), Size(740, 390)]) {
      await mount(tester, client, entries, size: size, back: () => backs++);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Banner 5 of 5'), findsOneWidget);
      if (size.width == 1200) {
        await tester.tap(find.byTooltip('Pause carousel'));
        await tester.pump(const Duration(seconds: 9));
        final controller = tester.widget<PageView>(find.byType(PageView)).controller!;
        expect(controller.page, 0);
        await tester.tap(find.byTooltip('Resume carousel'));
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(controller.page, 1);
        final hero = tester
            .widgetList<Focus>(find.byType(Focus))
            .firstWhere((w) => w.focusNode?.debugLabel == 'ted_home_banner');
        hero.focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(controller.page, 2);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        expect(backs, 1);
      }
      final evidence = Platform.environment['TED_BANNER_EVIDENCE_DIR'];
      if (evidence != null) {
        if (live != null) {
          // Native decoders run outside FakeAsync. Precache the saved bytes so
          // the first desktop capture also contains the completed artwork.
          await tester.runAsync(() async {
            final context = tester.element(find.byKey(const ValueKey('banner-render')));
            for (final bytes in live.artwork.values) {
              await precacheImage(MemoryImage(bytes), context);
              await precacheImage(ResizeImage.resizeIfNeeded(1920, null, MemoryImage(bytes)), context);
            }
          });
          await mount(tester, live, live.entries, size: size);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 2));
          expect(tester.takeException(), isNull);
        }
        Future<void> capture(String name) async {
          // Include the real parent surface so transparent artwork is composed
          // as in the app, rather than exporting the isolated alpha layer.
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('banner-page-render')));
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            try {
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              await File('$evidence/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }

        await capture('banner-${size.width.toInt()}x${size.height.toInt()}');
        if (live != null && size.width == 1200) {
          await tester.tap(find.byTooltip('Pause carousel'));
          await tester.pumpAndSettle();
          await capture('banner-paused-1200x900');
          await tester.tap(find.byTooltip('Resume carousel'));
          await tester.pump();
          await tester.runAsync(() async {
            final context = tester.element(find.byKey(const ValueKey('banner-render')));
            for (final logo in live.logos) {
              await precacheImage(
                ToneMappedLogoImage(
                  ResizeImage.resizeIfNeeded(1200, null, MemoryImage(logo)),
                  target: monoTheme(dark: false).colorScheme.onSurface,
                  remapMixed: false,
                ),
                context,
              );
            }
          });
          await mount(tester, live, live.entries, size: size, dark: false);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await capture('banner-light-1200x900');
        }
      }
    }
  });
  testWidgets('five-second autoplay continues under a stationary mouse and retained focus, and wraps', (tester) async {
    final client = BannerFixture();
    cleanup(tester, client);
    await mount(tester, client, List.generate(3, (i) => bannerTitle(i + 1, enrichment: false)));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 200));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(1000, 210));
    final hero = tester
        .widgetList<Focus>(find.byType(Focus))
        .firstWhere((w) => w.focusNode?.debugLabel == 'ted_home_banner');
    hero.focusNode!.requestFocus();
    await tester.pump();
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    await tester.pump(const Duration(seconds: 4));
    expect(pages.page, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    expect(hero.focusNode!.hasFocus, true);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(pages.page, 2);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(pages.page, 0);
  });
  testWidgets('active pill fills with advancement, stays full when paused and resets on manual paging', (tester) async {
    final client = BannerFixture();
    cleanup(tester, client);
    final entries = List.generate(3, (i) => bannerTitle(i + 1, enrichment: false));
    await mount(tester, client, entries);
    await tester.pump();
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    double fill(int index) => tester.getSize(find.byKey(ValueKey('banner-progress-$index'))).width;
    double track(int index) => tester.getSize(find.byKey(ValueKey('banner-indicator-$index'))).width;
    expect(fill(0), lessThan(track(0) / 2));
    await tester.pump(const Duration(milliseconds: 2500));
    expect(fill(0), closeTo(16, .5));
    expect(pages.page, 0);
    await tester.tap(find.byTooltip('Pause carousel'));
    await tester.pump();
    expect(fill(0), track(0));
    await tester.pump(const Duration(seconds: 8));
    expect(fill(0), track(0));
    expect(pages.page, 0);
    await tester.tap(find.byTooltip('Next banner'));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    expect(fill(1), track(1));
    await tester.tap(find.byTooltip('Resume carousel'));
    await tester.pump();
    expect(fill(1), lessThan(track(1) / 2));
    await tester.pump(const Duration(seconds: 2));
    expect(fill(1), closeTo(14.4, .5));
    await tester.tap(find.byTooltip('Next banner'));
    await tester.pumpAndSettle();
    expect(pages.page, 2);
    expect(fill(2), lessThan(track(2) / 2));
    await tester.pump(const Duration(seconds: 4));
    expect(pages.page, 2);
    expect(fill(2), greaterThan(track(2) * .8));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(pages.page, 0);
    expect(fill(0), lessThan(track(0) / 2));
    await mount(tester, client, entries, epoch: 1);
    await tester.pump();
    expect(fill(0), lessThan(track(0) / 2));
    expect(tester.takeException(), isNull);
  });
  testWidgets('autoplay waits for playback and backgrounding, and honors reduced motion', (tester) async {
    final client = BannerFixture(), stopped = Completer<void>();
    cleanup(tester, client);
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    final entries = [bannerTitle(1, enrichment: false), bannerTitle(2, enrichment: false)];
    await mount(tester, client, entries, play: (_) => stopped.future);
    await tester.pumpAndSettle();
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    await tester.tap(find.byType(FilledButton).first);
    await tester.pump(const Duration(seconds: 8));
    expect(pages.page, 0);
    stopped.complete();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 8));
    expect(pages.page, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    await mount(tester, client, entries, reducedMotion: true);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 8));
    expect(pages.page, 1);
  });
  testWidgets('banner artwork fades gradually from higher up to a transparent bottom in both themes', (tester) async {
    final client = BannerFixture();
    cleanup(tester, client);
    for (final dark in [true, false]) {
      await mount(tester, client, [bannerTitle(1, enrichment: false)], dark: dark);
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('banner-render')));
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          int alpha(double fraction) =>
              data!.getUint8((((image.height * fraction).floor() * image.width) + image.width - 8) * 4 + 3);
          return [alpha(.15), alpha(.45), alpha(.65), alpha(.85), alpha((image.height - 2) / image.height)];
        } finally {
          image.dispose();
        }
      });
      expect(pixels![0], 255);
      // The previous mask was fully opaque here and only began fading at 55%.
      expect(pixels[1], inInclusiveRange(190, 220));
      expect(pixels[2], inInclusiveRange(125, 155));
      expect(pixels[3], inInclusiveRange(25, 50));
      expect(pixels[4], lessThanOrEqualTo(4));
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('banner shading does not change across a horizontal line in either theme', (tester) async {
    final client = BannerFixture();
    cleanup(tester, client);
    for (final dark in [true, false]) {
      await mount(tester, client, [bannerTitle(1, enrichment: false)], dark: dark);
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('banner-render')));
      final samples = await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          final y = (image.height * .1).floor(); // Clear of title/actions.
          return [
            for (final x in [(image.width * .1).floor(), (image.width * .5).floor(), (image.width * .9).floor()])
              [for (var channel = 0; channel < 4; channel++) data!.getUint8((y * image.width + x) * 4 + channel)],
          ];
        } finally {
          image.dispose();
        }
      });
      expect(samples![0], samples[1]);
      expect(samples[1], samples[2]);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('floating header darkens evenly across the top and fades vertically without blocking controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(740, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('header-gradient-render'),
            child: ColoredBox(color: Colors.white, child: const TedBrowseHeader()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('header-gradient-render')));
    final samples = await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return [
          for (final y in [2, 50, 110])
            [
              for (final x in [8, image.width ~/ 2, image.width - 8]) data!.getUint8((y * image.width + x) * 4),
            ],
        ];
      } finally {
        image.dispose();
      }
    });
    for (final row in samples!) {
      expect(row[0], row[1]);
      expect(row[1], row[2]);
    }
    // Moderate darkening over white, stronger than the prior 31% top opacity.
    expect(samples[0][0], inInclusiveRange(90, 125));
    expect(samples[1][0], greaterThan(samples[0][0]));
    expect(samples[2][0], greaterThanOrEqualTo(250));
    expect(tester.takeException(), isNull);
  });

  testWidgets('episode artwork retains safe top spacing in short landscape and narrow windows', (tester) async {
    final client = BannerFixture();
    cleanup(tester, client);
    final episode = TedTitle.fromJson({
      ...titleData(kind: 'episode', id: 'tt1234502:1:3'),
      'parent': {'kind': 'series', 'id': 'tt1234502'},
      'metadata': {
        'series': {'name': 'Show title'},
        'episode': {'name': 'Third episode', 'season': 1, 'number': 3},
      },
    });
    for (final size in const [Size(740, 390), Size(420, 390), Size(320, 390)]) {
      await mount(tester, client, [episode], size: size);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byType(ClearLogoImage)).dy, greaterThanOrEqualTo(56));
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('late refresh/account results cannot replace current selection; provider failure retains fallback', (
    tester,
  ) async {
    final client = BannerFixture();
    cleanup(tester, client);
    final old = bannerTitle(1, enrichment: false), fresh = bannerTitle(2, enrichment: false);
    client.held[old.media] = Completer();
    await mount(tester, client, [old]);
    await tester.pump();
    await mount(tester, client, [fresh], epoch: 1);
    await tester.pumpAndSettle();
    client.held[old.media]!.complete(bannerTitle(1));
    await tester.pumpAndSettle();
    expect(find.text('Enriched 2'), findsOneWidget);
    expect(find.text('Enriched 1'), findsNothing);
    final other = BannerFixture();
    addTearDown(other.auth.close);
    other.held[fresh.media] = Completer();
    await mount(tester, other, [fresh], epoch: 2);
    await tester.pump();
    expect(find.text('Fallback 2'), findsOneWidget);
    expect(find.text('Enriched 2'), findsNothing);
    other.held[fresh.media]!.completeError(const TedFailure('unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Fallback 2'), findsOneWidget);
    expect(find.byTooltip('Metadata is unavailable. Retry to load it.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
