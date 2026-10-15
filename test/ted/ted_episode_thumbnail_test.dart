import 'dart:async';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/prefs.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/services/image_cache_service.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_personal_thumbnail.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/utils/media_image_helper.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import '../test_helpers/io_fakes.dart' show FakePathProvider;
import 'ted_catalog_test.dart' show CatalogFixture, titleData;
import 'ted_home_banner_test.dart' show pixel;
import 'ted_metadata_client_test.dart' show metadataData, assetId;

TedTitle thumbnailTitle(int n, {String? status, String? poster, String? episodePoster}) => TedTitle.fromJson({
  ...titleData(kind: 'episode', id: 'tt1234567:1:$n'),
  'parent': {'kind': 'series', 'id': 'tt1234567'},
  'metadata': {
    'poster': ?poster,
    'series': {'name': 'Show'},
    'episode': {'name': 'Episode $n', 'season': 1, 'number': n, 'image': ?episodePoster},
  },
  if (status != null) 'enrichment': thumbnailMetadata(status: status),
});

Map<String, dynamic> thumbnailMetadata({String status = 'ready'}) => {
  ...metadataData(status: status),
  'item': {...metadataData()['item'] as Map<String, dynamic>, 'Type': 'Episode'},
  'images': [
    {'id': assetId, 'type': 'Primary', 'index': 0, 'status': 'new', 'url': '/api/client/v1/metadata/images/$assetId'},
  ],
};

class ThumbnailFixture extends CatalogFixture {
  final reads = <TedMediaIdentity>[];
  final held = <TedMediaIdentity, Completer<TedTitle>>{};
  Completer<Uint8List>? heldImage;
  bool fail = false, pending = false, pendingImage = false;
  int polls = 0, images = 0;
  final imageIds = <String>[];
  @override
  Future<TedTitle> title(TedMediaIdentity media) async {
    reads.add(media);
    if (held.containsKey(media)) return held[media]!.future;
    if (fail) throw const TedFailure('unavailable');
    return thumbnailTitle(int.parse(media.id.split(':').last), status: pending ? 'queued' : 'ready');
  }

  @override
  Future<TedMetadataSnapshot> metadata(String id) async {
    polls++;
    return TedMetadataSnapshot.fromJson(thumbnailMetadata());
  }

  @override
  Future<Uint8List?> metadataImage(String id) async {
    images++;
    imageIds.add(id);
    if (heldImage != null) return heldImage!.future;
    return pendingImage && images == 1 ? null : pixel;
  }
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });
  const poster = 'https://images.metahub.space/poster/tt1234567.jpg',
      episodePoster = 'https://images.metahub.space/episode/tt1234567/1/2.jpg';
  TedTitle movie({bool enriched = true, int generation = 1, String background = ''}) => TedTitle.fromJson({
    ...titleData(id: 'tt1345836'),
    'metadata': {'name': 'The Dark Knight Rises', 'poster': poster, 'background': background},
    if (enriched)
      'enrichment': {
        ...metadataData(images: true),
        'generation': generation,
        'images': [
          {
            'id': '33333333-3333-4333-8333-333333333333',
            'type': 'Primary',
            'index': 0,
            'status': 'ready',
            'url': '/api/client/v1/metadata/images/33333333-3333-4333-8333-333333333333',
          },
          ...(metadataData(images: true)['images'] as List),
        ],
      },
  });
  final originalPaths = PathProviderPlatform.instance;
  late Directory cacheDirectory;
  setUp(() => PaintingBinding.instance.imageCache.clear());
  setUpAll(() async {
    cacheDirectory = Directory.systemTemp.createTempSync('ted-episode-thumbnail-cache-');
    PathProviderPlatform.instance = FakePathProvider(cacheDirectory);
    // Seed the existing public cache, outside widget-test FakeAsync. These
    // regressions decode real image frames without making network requests.
    for (final url in [poster, episodePoster]) {
      final provider =
          MediaImageHelper.serverArtworkProvider(imageUrl: url, memWidth: 0, memHeight: 0)
              as CachedNetworkImageProvider;
      await PlexImageCacheManager.instance.putFile(url, pixel, key: provider.cacheKey, fileExtension: 'png');
    }
  });
  tearDownAll(() async {
    await PlexImageCacheManager.instance.dispose();
    PathProviderPlatform.instance = originalPaths;
    cacheDirectory.deleteSync(recursive: true);
  });

  final fallback = find.byType(OptimizedMediaImage);
  final privateImage = find.byWidgetPredicate(
    (widget) =>
        widget is Image && widget.image is ResizeImage && (widget.image as ResizeImage).imageProvider is MemoryImage,
  );
  Future<void> mount(WidgetTester tester, TedPersonalArtwork owner, TedTitle episode) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox).last);
    final ratio = MediaImageHelper.artworkPixelRatio(context, imageType: ImageType.thumb);
    final (width, height) = MediaImageHelper.getMemCacheDimensions(
      displayWidth: (320 * ratio).round(),
      displayHeight: (180 * ratio).round(),
      imageType: ImageType.thumb,
    );
    final paths = episode.media.kind == 'movie'
        ? {if (episode.background.isNotEmpty) episode.background, episode.poster}
        : {episode.episodePoster.isNotEmpty ? episode.episodePoster : episode.poster};
    // Start file I/O outside FakeAsync, before the card attaches its image
    // stream. Otherwise awaiting that same pending stream deadlocks the test.
    for (final path in paths.where((path) => path.isNotEmpty)) {
      await tester.runAsync(
        () => precacheImage(
          MediaImageHelper.serverArtworkProvider(imageUrl: path, memWidth: width, memHeight: height),
          context,
          onError: (_, _) {},
        ),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 180,
            child: TedPersonalThumbnail(artwork: owner, title: episode),
          ),
        ),
      ),
    );
  }

  Future<void> decodeFallback(WidgetTester tester, String path) async {
    expect(tester.widget<OptimizedMediaImage>(fallback).imagePath, path);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<RawImage>(find.descendant(of: fallback, matching: find.byType(RawImage))).image, isNotNull);
  }

  testWidgets('movie without a Cinemeta backdrop keeps its poster until cached TMDb artwork decodes', (tester) async {
    final client = ThumbnailFixture()..heldImage = Completer<Uint8List>();
    final owner = TedPersonalArtwork(client);
    addTearDown(client.auth.close);
    addTearDown(owner.dispose);
    await mount(tester, owner, movie());
    await decodeFallback(tester, poster);
    expect(client.reads, isEmpty);
    expect(client.polls, 0);
    expect(client.imageIds, [assetId], reason: 'The wide backdrop takes precedence over the poster asset.');
    client.heldImage!.complete(pixel);
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() => precacheImage(tester.widget<Image>(privateImage).image, tester.element(privateImage)));
    await tester.pump();
    expect(fallback, findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('spoiler preference blurs started episode art and releases watched art immediately', (tester) async {
    final client = ThumbnailFixture();
    final owner = TedPersonalArtwork(client, loadEpisodeDetails: false);
    addTearDown(client.auth.close);
    addTearDown(owner.dispose);
    final started = thumbnailTitle(1, poster: poster);
    await mount(tester, owner, started);
    expect(started.positionMs, greaterThan(0));
    expect(find.byType(ImageFiltered), findsNothing);
    await SettingsService.instance.write(SettingsService.hideSpoilers, true);
    await tester.pump();
    expect(find.byType(ImageFiltered), findsOneWidget);
    final watched = TedTitle.fromJson({
      ...titleData(kind: 'episode', id: started.media.id, played: true),
      'parent': {'kind': 'series', 'id': 'tt1234567'},
      'metadata': {
        'poster': poster,
        'episode': {'season': 1, 'number': 1},
      },
    });
    await mount(tester, owner, watched);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('cold movies do not fetch metadata and later cache generations fence obsolete transfers', (tester) async {
    final client = ThumbnailFixture();
    final owner = TedPersonalArtwork(client);
    addTearDown(client.auth.close);
    addTearDown(owner.dispose);
    await mount(tester, owner, movie(enriched: false));
    await decodeFallback(tester, poster);
    expect(client.reads, isEmpty);
    expect(client.images, 0);
    expect(find.byTooltip('Retry movie thumbnail'), findsNothing);
    Future<void> update(TedTitle title) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 180,
            child: TedPersonalThumbnail(artwork: owner, title: title),
          ),
        ),
      ),
    );
    final first = client.heldImage = Completer<Uint8List>();
    await update(movie());
    await tester.pump();
    final latest = client.heldImage = Completer<Uint8List>();
    final refreshed = movie(generation: 2);
    await update(refreshed);
    await tester.pump();
    latest.complete(pixel);
    await tester.pump();
    await tester.pump();
    first.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pump();
    final image = tester.widget<Image>(privateImage).image as ResizeImage;
    expect((image.imageProvider as MemoryImage).bytes, pixel);
    expect(await owner.load(refreshed), pixel);
    expect(client.images, 2);
    expect(client.reads, isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed Cinemeta movie backdrops fall back to the poster without waiting for enrichment', (tester) async {
    final client = ThumbnailFixture(), owner = TedPersonalArtwork(client);
    addTearDown(client.auth.close);
    addTearDown(owner.dispose);
    await mount(tester, owner, movie(enriched: false, background: episodePoster));
    await decodeFallback(tester, episodePoster);
    final background = tester.widget<OptimizedMediaImage>(fallback);
    // Exercise the image loader's failure callback at its owning boundary.
    // Corrupt disk-cache files otherwise cause the cache manager to re-fetch,
    // which is unrelated to TED's fallback and depends on external networking.
    final replacement = background.errorWidget!(
      tester.element(fallback),
      episodePoster,
      const FormatException('undecodable image'),
    );
    await tester.pumpWidget(MaterialApp(home: SizedBox(width: 320, height: 180, child: replacement)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final posterImage = find.byWidgetPredicate((w) => w is OptimizedMediaImage && w.imagePath == poster);
    expect(posterImage, findsOneWidget);
    expect(tester.widget<RawImage>(find.descendant(of: posterImage, matching: find.byType(RawImage))).image, isNotNull);
    expect(client.reads, isEmpty);
    expect(client.images, 0);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('previous show artwork stays visible through metadata, image transfer and first-frame decoding', (
    tester,
  ) async {
    final client = ThumbnailFixture()..heldImage = Completer<Uint8List>();
    final owner = TedPersonalArtwork(client), episode = thumbnailTitle(1, poster: poster);
    client.held[episode.media] = Completer<TedTitle>();
    addTearDown(client.auth.close);
    addTearDown(owner.dispose);
    await mount(tester, owner, episode);
    await decodeFallback(tester, poster);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    client.held[episode.media]!.complete(thumbnailTitle(1, status: 'ready'));
    await tester.pump();
    expect(client.images, 1);
    expect(fallback, findsOneWidget);
    client.heldImage!.complete(pixel);
    await tester.pump();
    await tester.pump();
    expect(privateImage, findsOneWidget);
    expect(fallback, findsOneWidget, reason: 'Received bytes do not yet establish a decoded frame.');
    await tester.runAsync(() => precacheImage(tester.widget<Image>(privateImage).image, tester.element(privateImage)));
    await tester.pump();
    expect(fallback, findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(client.reads, [episode.media]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cinemeta episode artwork survives provider failure, retry and an undecodable replacement', (
    tester,
  ) async {
    final client = ThumbnailFixture()..fail = true;
    final owner = TedPersonalArtwork(client), episode = thumbnailTitle(2, poster: poster, episodePoster: episodePoster);
    addTearDown(client.auth.close);
    addTearDown(owner.dispose);
    await mount(tester, owner, episode);
    await tester.pump();
    await decodeFallback(tester, episodePoster);
    expect(find.byTooltip('Retry episode thumbnail'), findsOneWidget);
    client
      ..fail = false
      ..heldImage = Completer<Uint8List>();
    await tester.tap(find.byTooltip('Retry episode thumbnail'));
    await tester.pump();
    expect(fallback, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    client.heldImage!.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pump();
    Object? decodeError;
    await tester.runAsync(
      () => precacheImage(
        tester.widget<Image>(privateImage).image,
        tester.element(privateImage),
        onError: (error, _) => decodeError = error,
      ),
    );
    await tester.pump();
    expect(decodeError, isNotNull);
    await decodeFallback(tester, episodePoster);
    expect(client.reads, [episode.media, episode.media]);
    expect(tester.takeException(), isNull);
  });

  test('lazy requests coalesce and hold five workflow slots through image delivery', () async {
    final client = ThumbnailFixture()..heldImage = Completer<Uint8List>();
    final owner = TedPersonalArtwork(client);
    addTearDown(client.auth.close);
    addTearDown(owner.dispose);
    final entries = [for (var n = 1; n <= 6; n++) thumbnailTitle(n)];
    for (final title in entries) {
      client.held[title.media] = Completer<TedTitle>();
    }
    expect(client.reads, isEmpty);
    final first = owner.load(entries[0]);
    final same = owner.load(entries[0]);
    final rest = [for (final title in entries.skip(1)) owner.load(title)];
    expect(identical(first, same), true);
    expect(client.reads, entries.take(5).map((e) => e.media).toList());
    client.held[entries[0].media]!.complete(thumbnailTitle(1, status: 'ready'));
    await Future<void>.delayed(Duration.zero);
    expect(client.images, 1);
    expect(client.reads.length, 5, reason: 'A workflow remains active while the image is pending.');
    client.heldImage!.complete(pixel);
    expect(await first, pixel);
    await Future<void>.delayed(Duration.zero);
    expect(client.reads, entries.map((e) => e.media).toList());
    for (var i = 1; i < entries.length; i++) {
      client.held[entries[i].media]!.complete(thumbnailTitle(i + 1, status: 'ready'));
    }
    await Future.wait([same, ...rest]);
    expect(await owner.load(entries[0]), pixel);
    expect(client.reads.length, 6);
    expect(client.images, 6);
  });

  testWidgets('seeded thumbnail loads without waiting for pending full episode metadata', (tester) async {
    final client = ThumbnailFixture()
      ..pending = true
      ..pendingImage = true;
    final owner = TedPersonalArtwork(client), episode = thumbnailTitle(1);
    addTearDown(client.auth.close);
    addTearDown(owner.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 320,
          height: 180,
          child: TedPersonalThumbnail(artwork: owner, title: episode),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(client.polls, 0);
    expect(client.images, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(client.images, 2);
    expect(client.polls, 0);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(client.reads, [episode.media]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider failure can retry and disposed owners discard queued and late private images', (tester) async {
    final client = ThumbnailFixture()..fail = true;
    final owner = TedPersonalArtwork(client);
    addTearDown(client.auth.close);
    addTearDown(owner.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 320,
          height: 180,
          child: TedPersonalThumbnail(artwork: owner, title: thumbnailTitle(1)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Retry episode thumbnail'), findsOneWidget);
    client.fail = false;
    await tester.tap(find.byTooltip('Retry episode thumbnail'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byTooltip('Retry episode thumbnail'), findsNothing);
    final other = ThumbnailFixture(), stale = TedPersonalArtwork(other);
    addTearDown(other.auth.close);
    final entries = [for (var n = 1; n <= 6; n++) thumbnailTitle(n)];
    for (final episode in entries) {
      other.held[episode.media] = Completer<TedTitle>();
    }
    final late = [for (final episode in entries) stale.load(episode)];
    stale.dispose();
    expect(await Future.wait(late), everyElement(isNull));
    for (var i = 0; i < entries.length; i++) {
      other.held[entries[i].media]!.complete(thumbnailTitle(i + 1, status: 'ready'));
    }
    await tester.pump();
    expect(other.images, 0);
    expect(await stale.load(thumbnailTitle(3)), isNull);
    expect(other.reads, entries.take(5).map((e) => e.media).toList());
    expect(tester.takeException(), isNull);
  });
}
