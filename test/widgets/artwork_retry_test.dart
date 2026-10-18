import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/image_cache_service.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_browse_screen.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_home_banner.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import '../ted/ted_browse_test.dart' show BrowseFixture;
import '../ted/ted_catalog_test.dart' show titleData;
import '../ted/ted_home_banner_test.dart' show BannerFixture;
import '../test_helpers/prefs.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

// Widget tests exercise the real provider/decoder and cache protocol with
// real files, while the actual Hive cache is tested in image_cache_service_test.
// Hive write futures must not survive a widget test's fake-async zone.
class _Cache extends PlexImageCacheManager {
  final List<Uri> requests;
  final http.Response Function(Uri) response;
  final FileInfo good, corrupt;
  final _files = <String, FileInfo>{};
  _Cache(Directory directory, this.requests, this.response, this.good, this.corrupt)
    : super.forTesting(
        cacheDirectoryProvider: () async => directory,
        httpClientFactory: () => MockClient((_) async => http.Response('', 500)),
      );
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    key ??= url;
    final saved = _files[key];
    if (saved != null) {
      yield saved;
      return;
    }
    final uri = Uri.parse(url);
    requests.add(uri);
    final result = response(uri);
    if (result.statusCode != 200) throw HttpException('artwork status ${result.statusCode}');
    final source = listEquals(result.bodyBytes, _pixel) ? good : corrupt;
    final info = FileInfo(source.file, FileSource.Online, source.validTill, url);
    _files[key] = info;
    yield info;
  }

  @override
  Future<void> removeFile(String key) async {
    _files.remove(key);
  }
}

class _PosterBrowse extends BrowseFixture {
  final int count;
  _PosterBrowse({this.count = 1});
  @override
  Future<List<TedHomeRow>> home({void Function(List<TedHomeRow>)? onUpdate}) async => [
    for (final kind in ['movie', 'series'])
      TedHomeRow(
        'popular-$kind',
        [
          for (var i = 0; i < count; i++)
            TedTitle.fromJson({
              ...titleData(kind: kind, id: 'tt${(kind == 'movie' ? 1234567 : 8888888) + i}'),
              'metadata': {
                'name': kind == 'movie' ? 'Poster movie' : 'Poster show',
                'poster': 'https://images.metahub.space/home-$kind-$i.png',
                'year': '2026',
              },
            }),
        ],
        false,
        [],
      ),
  ];
}

void main() {
  late Directory directory;
  late FileInfo good, corrupt, portrait;
  late http.Response Function(Uri) response;
  late List<Uri> requests;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('teddy-artwork-retry');
    final cache = PlexImageCacheManager.forTesting(
      cacheDirectoryProvider: () async => directory,
      httpClientFactory: () =>
          MockClient((request) async => http.Response.bytes(request.url.path == '/good' ? _pixel : [1, 2, 3], 200)),
    );
    good = await cache.getFileStream('https://fixture.invalid/good').firstWhere((v) => v is FileInfo) as FileInfo;
    corrupt = await cache.getFileStream('https://fixture.invalid/corrupt').firstWhere((v) => v is FileInfo) as FileInfo;
    await cache.dispose();
    final recording = ui.PictureRecorder();
    ui.Canvas(recording).drawColor(const Color(0xff39505a), ui.BlendMode.src);
    final picture = recording.endRecording();
    final image = await picture.toImage(1600, 2400);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = good.file.parent.childFile('portrait.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    portrait = FileInfo(file, FileSource.Cache, DateTime.now().add(const Duration(days: 1)), 'portrait');
  });
  tearDownAll(() => directory.delete(recursive: true));
  setUp(() {
    requests = [];
    response = (_) => http.Response.bytes(_pixel, 200, headers: {'content-type': 'image/png'});
    PlexImageCacheManager.debugInstance = _Cache(directory, requests, (url) => response(url), good, corrupt);
    DevicePerformance.debugReset(autoReduced: false);
  });

  Widget artwork(String path, {bool enabled = true}) => MaterialApp(
    home: TickerMode(
      enabled: enabled,
      child: Center(
        child: OptimizedMediaImage.poster(
          imagePath: 'https://images.metahub.space/$path.png',
          width: 100,
          height: 150,
          placeholder: (_, _) => const Text('loading'),
          errorWidget: (_, _, _) => const Text('failed'),
        ),
      ),
    ),
  );

  // Let the actual disk cache and Flutter decoder finish outside fake time.
  Future<void> io(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() async {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
  }

  Future<void> loaded(WidgetTester tester, {bool failed = true, required int count}) async {
    // Disk streams and codec completion cross from real IO into fake async
    // several times. Wait for that observable terminal state, never advance
    // the retry clock to hide a failure or trigger another request.
    for (var turn = 0; turn < 30; turn++) {
      await io(tester);
      final ready = failed
          ? find.text('failed').evaluate().isNotEmpty
          : find.byType(RawImage).evaluate().any((v) => (v.widget as RawImage).image != null);
      if (ready && requests.length == count) return;
    }
    fail(
      'Artwork did not reach its expected ${failed ? 'failure' : 'decoded'} state; requests: $requests, texts: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data)}',
    );
  }

  Future<void> initialize(WidgetTester tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await io(tester);
      PlexImageCacheManager.debugInstance = null;
      DevicePerformance.debugReset();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
  }

  testWidgets('Cinemeta spotlight bounds portrait decoding on both axes and reuses the shared disk cache', (
    tester,
  ) async {
    await initialize(tester);
    DevicePerformance.debugReset(autoReduced: true);
    PlexImageCacheManager.debugInstance = _Cache(directory, requests, (url) => response(url), portrait, corrupt);
    final client = BannerFixture();
    addTearDown(client.auth.close);
    final title = TedTitle.fromJson({
      ...titleData(),
      'metadata': {'name': 'Portrait fallback', 'poster': 'https://images.metahub.space/portrait.png'},
    });
    Widget preview() => MaterialApp(
      home: Scaffold(
        body: TedHomeBanner(
          client: client,
          entries: [title],
          refreshEpoch: 0,
          catalogPreview: true,
          enrichMetadata: false,
          onPlay: (_) async {},
          onOpen: (_) async {},
          onBack: () {},
        ),
      ),
    );
    await tester.pumpWidget(preview());
    await loaded(tester, failed: false, count: 1);
    final decoded = tester.widgetList<RawImage>(find.byType(RawImage)).map((w) => w.image).whereType<ui.Image>().single;
    expect(decoded.width, lessThanOrEqualTo(480));
    expect(decoded.height, lessThanOrEqualTo(720));
    expect(decoded.width / decoded.height, closeTo(2 / 3, .01));
    expect(client.requests, isEmpty);
    expect(client.polls, 0);
    expect(client.imageRequests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await io(tester);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pumpWidget(preview());
    await loaded(tester, failed: false, count: 1);
    expect(requests, hasLength(1), reason: 'Revisiting after memory eviction must reuse cached Cinemeta bytes');
    expect(tester.takeException(), isNull);
  });

  testWidgets('posters remain painted after leaving and returning to a lazy horizontal list', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 500,
            height: 240,
            child: ListView.builder(
              controller: scroll,
              scrollDirection: Axis.horizontal,
              itemExtent: 160,
              itemCount: 30,
              addAutomaticKeepAlives: false,
              itemBuilder: (_, i) => OptimizedMediaImage.poster(
                key: ValueKey(i),
                imagePath: 'https://images.metahub.space/remount-$i.png',
                width: 160,
                height: 240,
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> settleImages() async {
      for (var i = 0; i < 15; i++) {
        await io(tester);
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    void expectVisible() {
      final raw = tester.widget<RawImage>(
        find.descendant(of: find.byKey(const ValueKey(0)), matching: find.byType(RawImage)),
      );
      expect(raw.image, isNotNull);
      expect(raw.opacity?.value ?? 1, 1);
    }

    await settleImages();
    expectVisible();
    scroll.jumpTo(3200);
    await settleImages();
    expect(find.byKey(const ValueKey(0)), findsNothing);
    PaintingBinding.instance.imageCache.clear();
    scroll.jumpTo(0);
    await settleImages();
    expectVisible();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed HTTP and corrupt cached bytes automatically recover without a rebuild', (tester) async {
    await initialize(tester);
    response = (_) => switch (requests.length) {
      1 => http.Response('temporary outage', 503),
      2 => http.Response('not an image', 200, headers: {'content-type': 'image/png'}),
      _ => http.Response.bytes(_pixel, 200, headers: {'content-type': 'image/png'}),
    };
    await tester.pumpWidget(artwork('recover'));
    await loaded(tester, count: 1);
    expect(requests, hasLength(1));
    expect(find.text('failed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await loaded(tester, count: 2);
    expect(requests, hasLength(2));
    expect(find.text('failed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await loaded(tester, failed: false, count: 3);
    await tester.pump(const Duration(milliseconds: 300));
    expect(requests, hasLength(3), reason: 'bad cached bytes must be replaced by a fresh download');
    expect(find.text('failed'), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await tester.pump(const Duration(minutes: 2));
    expect(requests, hasLength(3), reason: 'successful images must stop retrying');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('persistent failures back off, pause offstage and stop after disposal', (tester) async {
    await initialize(tester);
    DevicePerformance.debugReset(autoReduced: true);
    response = (_) => http.Response('outage', 503);
    await tester.pumpWidget(artwork('outage'));
    await loaded(tester, count: 1);
    await tester.pump(const Duration(seconds: 1));
    expect(requests, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    await loaded(tester, count: 2);
    expect(requests, hasLength(2));
    await tester.pump(const Duration(seconds: 3));
    expect(requests, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
    await loaded(tester, count: 3);
    expect(requests, hasLength(3));
    await tester.pumpWidget(artwork('outage', enabled: false));
    await tester.pump(const Duration(minutes: 2));
    expect(requests, hasLength(3));
    await tester.pumpWidget(artwork('outage'));
    await tester.pump(const Duration(seconds: 8));
    await loaded(tester, count: 4);
    expect(requests, hasLength(4), reason: 'returning to the page resumes recovery');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
    expect(requests, hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the title cancels its old retry and preserves a successful cached image', (tester) async {
    await initialize(tester);
    response = (url) => url.path.contains('missing')
        ? http.Response('missing', 404)
        : http.Response.bytes(_pixel, 200, headers: {'content-type': 'image/png'});
    await tester.pumpWidget(artwork('missing'));
    await loaded(tester, count: 1);
    await tester.pumpWidget(artwork('ready'));
    await loaded(tester, failed: false, count: 2);
    await tester.pump(const Duration(milliseconds: 300));
    expect(requests.map((u) => u.path), ['/missing.png', '/ready.png']);
    await tester.pump(const Duration(minutes: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(artwork('ready'));
    await loaded(tester, failed: false, count: 2);
    expect(requests, hasLength(2));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('resizing a loaded poster keeps the cached frame opaque across repeated sidebar widths', (tester) async {
    await initialize(tester);
    double width = 100;
    late StateSetter resize;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            resize = setState;
            return Center(
              child: OptimizedMediaImage.poster(
                imagePath: 'https://images.metahub.space/resize.png',
                width: width,
                height: width * 1.5,
                placeholder: (_, _) => const Text('loading'),
                errorWidget: (_, _, _) => const Text('failed'),
              ),
            );
          },
        ),
      ),
    );
    await loaded(tester, failed: false, count: 1);
    await tester.pump(const Duration(milliseconds: 350));
    for (final next in [110.0, 130.0, 100.0, 130.0, 100.0]) {
      resize(() => width = next);
      await tester.pump();
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image,
        isNotNull,
        reason: 'A resize must retain the last decoded poster while the new decode is pending',
      );
      await loaded(tester, failed: false, count: 1);
      await tester.pump(const Duration(milliseconds: 350));
      final image = tester.widget<RawImage>(find.byType(RawImage));
      expect(image.image, isNotNull);
      expect(image.opacity?.value ?? 1, 1, reason: 'Cached poster must remain visible at width $next');
      expect(find.text('failed'), findsNothing);
    }
    for (final next in [170.0, 150.0, 155.0, 140.0, 135.0, 130.0, 125.0, 120.0, 115.0, 110.0, 105.0, 100.0]) {
      resize(() => width = next);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await loaded(tester, failed: false, count: 1);
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.widget<RawImage>(find.byType(RawImage)).opacity?.value ?? 1, 1);
    expect(requests, hasLength(1), reason: 'Layout changes must reuse the saved image bytes');
  });

  testWidgets('Home shelf posters survive scrolling out and returning with recycled cards', (tester) async {
    await initialize(tester);
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _PosterBrowse(count: 30);
    addTearDown(client.auth.close);
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: Scaffold(
            body: TedBrowseScreen(client: client, onPlay: (_) async {}),
          ),
        ),
      ),
    );
    await io(tester);
    InputModeTracker.reportNonPointerInput();
    final hub = tester.state<HubSectionState>(find.byType(HubSection).first);
    hub.requestFocusAt(0);
    await tester.pump();
    for (final direction in [LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowLeft]) {
      await tester.sendKeyDownEvent(direction);
      for (var step = 0; step < 25; step++) {
        await tester.sendKeyRepeatEvent(direction);
        await tester.pump(const Duration(milliseconds: 30));
        await io(tester);
      }
      await tester.sendKeyUpEvent(direction);
    }
    for (final index in [0, 20, 0, 25, 0]) {
      PaintingBinding.instance.imageCache.clear();
      hub.requestFocusAt(index);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (var turn = 0; turn < 15; turn++) {
        await io(tester);
      }
      await tester.pump(const Duration(milliseconds: 400));
      final images = tester
          .widgetList<RawImage>(find.descendant(of: find.byType(HubSection).first, matching: find.byType(RawImage)))
          .toList();
      expect(images, isNotEmpty);
      for (final image in images) {
        expect(image.image, isNotNull, reason: 'index $index');
        expect(image.opacity?.value ?? 1, 1, reason: 'index $index');
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('popular home posters survive pointer sidebar expansion and collapse in both layouts', (tester) async {
    await initialize(tester);
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 1800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
    for (final tv in [false, true]) {
      TvDetectionService.debugSetAppleTVOverride(tv);
      final client = _PosterBrowse();
      addTearDown(client.auth.close);
      await tester.pumpWidget(
        InputModeTracker(
          child: MaterialApp(
            key: UniqueKey(),
            theme: monoTheme(dark: true),
            home: Scaffold(
              body: TedBrowseScreen(client: client, onPlay: (_) async {}),
            ),
          ),
        ),
      );
      bool homeReady() => ['movie', 'series'].every((kind) {
        final images = tester.widgetList<RawImage>(
          find.descendant(of: find.byKey(ValueKey('popular-$kind')), matching: find.byType(RawImage)),
        );
        return images.length == 1 && images.single.image != null;
      });
      Future<void> homeLoaded() async {
        for (var turn = 0; turn < 30 && !homeReady(); turn++) {
          await io(tester);
        }
        expect(homeReady(), true, reason: 'Both home rows must decode before judging their visibility');
      }

      await homeLoaded();
      await tester.pump(const Duration(milliseconds: 350));
      InputModeTracker.reportNonPointerInput();
      tester
          .state<HubSectionState>(
            find.descendant(of: find.byKey(const ValueKey('popular-movie')), matching: find.byType(HubSection)),
          )
          .requestFocusAt(0);
      await tester.pump();
      for (final key in [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await homeLoaded();
        for (final kind in ['movie', 'series']) {
          final raw = tester.widget<RawImage>(
            find.descendant(of: find.byKey(ValueKey('popular-$kind')), matching: find.byType(RawImage)),
          );
          expect(raw.image, isNotNull);
          expect(raw.opacity?.value ?? 1, 1);
        }
      }
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 800));
      for (final position in [
        const Offset(20, 250),
        const Offset(700, 800),
        const Offset(20, 250),
        const Offset(700, 800),
      ]) {
        await mouse.moveTo(position);
        await tester.pump(); // start the sidebar width animation
        await tester.pump(const Duration(milliseconds: 350));
        await homeLoaded();
        await tester.pump(const Duration(milliseconds: 350));
        for (final kind in ['movie', 'series']) {
          final image = find.descendant(of: find.byKey(ValueKey('popular-$kind')), matching: find.byType(RawImage));
          expect(image, findsOneWidget);
          final raw = tester.widget<RawImage>(image);
          expect(raw.image, isNotNull, reason: 'Home $kind image in $tv layout after $position; requests: $requests');
          expect(raw.opacity?.value ?? 1, 1, reason: 'Home poster must paint in $tv layout after $position');
        }
      }
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
