import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/ted/ted_cast_row.dart';
import 'package:plezy/ted/ted_metadata_models.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/widgets/cast_member_strip.dart';
import 'package:plezy/utils/platform_detector.dart';
import '../test_helpers/prefs.dart';
import 'ted_catalog_test.dart' show CatalogFixture;
import 'ted_home_banner_test.dart' show pixel;

TedMetadataPerson person(int n, {bool image = true}) => TedMetadataPerson(
  id: '11111111-1111-4111-8111-${n.toString().padLeft(12, '0')}',
  name: 'Actor $n',
  type: 'Actor',
  role: 'Character $n',
  imageTag: image ? 'portrait-$n' : null,
);

class CastFixture extends CatalogFixture {
  final reads = <String>[];
  final held = <String, Completer<Uint8List?>>{};
  final missing = <String>{};
  bool hold = false, fail = false, pending = false;
  Uint8List? imageBytes;
  @override
  Future<Uint8List?> personPortrait(String id) async {
    reads.add(id);
    if (missing.contains(id)) throw const TedFailure('metadata_not_found');
    if (fail) throw const TedFailure('unavailable');
    if (hold) return (held[id] ??= Completer<Uint8List?>()).future;
    if (pending && reads.length == 1) return null;
    return imageBytes ?? pixel;
  }
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(true);
  });
  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
  Widget row(CastFixture client, List<TedMetadataPerson> people) => MaterialApp(
    theme: monoTheme(dark: true),
    home: Scaffold(
      body: TedCastRow(
        client: client,
        people: people,
        loading: false,
        horizontalInset: 24,
        onUp: () {},
        onLeft: () {},
        onBack: () {},
        onFocusChanged: (_) {},
      ),
    ),
  );

  testWidgets('visible portraits run five at a time and reuse bytes on rebuild', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final client = CastFixture()..hold = true;
    addTearDown(client.auth.close);
    final people = List.generate(14, person);
    await tester.pumpWidget(row(client, people));
    expect(client.reads, hasLength(5));
    final first = client.held.values.toList();
    first.first.complete(pixel);
    await tester.pump();
    expect(client.reads, hasLength(6));
    for (final completion in first.skip(1)) {
      completion.complete(pixel);
    }
    await tester.pump();
    for (final completion in client.held.values.where((c) => !c.isCompleted).toList()) {
      completion.complete(pixel);
    }
    await tester.pump();
    await tester.pumpWidget(row(client, people));
    expect(client.reads.toSet().length, client.reads.length);
    expect(find.byType(Image), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait decode preserves aspect ratio before cropping to taller TED cast cards', (tester) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 512, 1024), ui.Paint()..color = Colors.green);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(512, 1024));
    final encoded = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
    image!.dispose();
    picture.dispose();
    final client = CastFixture()..imageBytes = encoded!.buffer.asUint8List();
    addTearDown(client.auth.close);
    await tester.pumpWidget(row(client, [person(0)]));
    await tester.pump();
    final finder = find.byType(Image);
    expect(finder, findsOneWidget);
    await tester.runAsync(() => precacheImage(tester.widget<Image>(finder).image, tester.element(finder)));
    await tester.pump();
    final decoded = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(decoded.width / decoded.height, closeTo(.5, .01));
    expect(decoded.height, lessThan(1024));
    expect(tester.widget<Image>(finder).fit, BoxFit.cover);
    final rect = tester.getRect(finder);
    expect(rect.width / rect.height, closeTo(2 / 3, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed/missing and pending portraits retain credits, with bounded pending polling', (tester) async {
    final client = CastFixture()
      ..pending = true
      ..missing.add(person(1).id);
    addTearDown(client.auth.close);
    await tester.pumpWidget(row(client, [person(0, image: false), person(1, image: false)]));
    expect(find.text('Actor 0'), findsOneWidget);
    expect(find.text('Actor 1'), findsOneWidget);
    expect(client.reads, [person(0).id, person(1).id]);
    expect(find.byType(Image), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(client.reads, [person(0).id, person(1).id, person(0).id]);
    expect(find.byType(Image), findsOneWidget);
    client.fail = true;
    await tester.pumpWidget(row(client, [person(2)]));
    await tester.pump();
    expect(find.text('Actor 2'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing the credential owner drops queued work and ignores late portrait bytes', (tester) async {
    final old = CastFixture()..hold = true, replacement = CastFixture()..hold = true;
    addTearDown(old.auth.close);
    addTearDown(replacement.auth.close);
    final people = List.generate(14, person);
    await tester.pumpWidget(row(old, people));
    final held = old.held.values.toList();
    expect(old.reads, hasLength(5));
    await tester.pumpWidget(row(replacement, people));
    for (final completion in held) {
      completion.complete(pixel);
    }
    await tester.pump();
    expect(old.reads, hasLength(5));
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CastMemberStrip), findsOneWidget);
    expect(find.text('Actor 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    for (final completion in replacement.held.values) {
      completion.complete(pixel);
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
