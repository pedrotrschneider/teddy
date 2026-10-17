import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List masterBytes;
  late ui.Image master;
  setUpAll(() async {
    masterBytes = await File('icon.png').readAsBytes();
    master = await decode(masterBytes);
  });
  tearDownAll(() => master.dispose());

  Future<ui.Image> reference(int width, int height) async {
    final scale = width / master.width > height / master.height ? width / master.width : height / master.height;
    final sourceWidth = width / scale, sourceHeight = height / scale;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      master,
      ui.Rect.fromLTWH((master.width - sourceWidth) / 2, (master.height - sourceHeight) / 2, sourceWidth, sourceHeight),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final drawing = recorder.endRecording();
    try {
      return await drawing.toImage(width, height);
    } finally {
      drawing.dispose();
    }
  }

  Future<void> matchesMaster(ui.Image actual, String name) async {
    final expected = await reference(actual.width, actual.height);
    try {
      final a = (await actual.toByteData())!.buffer.asUint8List();
      final b = (await expected.toByteData())!.buffer.asUint8List();
      var difference = 0;
      for (var i = 0; i < a.length; i++) {
        difference += (a[i] - b[i]).abs();
      }
      // sips and Flutter use different resampling kernels at tiny icon sizes.
      expect(difference / a.length, lessThan(actual.width <= 32 ? 8 : 3), reason: name);
    } finally {
      expected.dispose();
    }
  }

  Future<void> matchesMask(ui.Image actual, String name) async {
    final expected = await reference(actual.width, actual.height);
    try {
      final a = (await actual.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
      final b = (await expected.toByteData())!.buffer.asUint8List();
      var intersection = 0, union = 0;
      for (var i = 0; i < a.length; i += 4) {
        final visible = a[i + 3] > 70;
        final ink = b[i] > 70 || b[i + 1] > 70 || b[i + 2] > 70;
        if (visible && ink) intersection++;
        if (visible || ink) union++;
        if (name.contains('lightunplated') && a[i + 3] > 240) {
          expect(a.sublist(i, i + 3).every((c) => c < 40), true, reason: name);
        }
      }
      expect(intersection / union, greaterThan(.65), reason: '$name must preserve the TED silhouette');
    } finally {
      expected.dispose();
    }
  }

  test('every TV density resolves to a wide TED banner without stretching the mark', () async {
    final manifest = await File('android/app/src/main/AndroidManifest.xml').readAsString();
    final banner = RegExp(r'android:banner="@drawable/(\w+)"').firstMatch(manifest)!.group(1)!;
    for (final (density, width, height) in [
      ('mdpi', 160, 90),
      ('hdpi', 240, 135),
      ('xhdpi', 320, 180),
      ('xxhdpi', 480, 270),
      ('xxxhdpi', 640, 360),
    ]) {
      final path = 'android/app/src/main/res/drawable-$density/$banner.png';
      final image = await decode(await File(path).readAsBytes());
      try {
        expect((image.width, image.height), (width, height), reason: path);
        await matchesMaster(image, path);
      } finally {
        image.dispose();
      }
    }
  });

  test('Android notification artwork is a visible white TED mask on transparency', () async {
    for (final (density, size) in [('mdpi', 24), ('hdpi', 36), ('xhdpi', 48), ('xxhdpi', 72), ('xxxhdpi', 96)]) {
      final image = await decode(
        await File('android/app/src/main/res/drawable-$density/ic_stat_notification.png').readAsBytes(),
      );
      try {
        expect((image.width, image.height), (size, size));
        final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
        var visible = 0, transparent = 0;
        for (var i = 0; i < pixels.length; i += 4) {
          if (pixels[i + 3] == 0) {
            transparent++;
            continue;
          }
          visible++;
          expect(pixels.sublist(i, i + 3), [255, 255, 255], reason: density);
        }
        expect(visible, greaterThan(0));
        expect(transparent, greaterThan(size * size ~/ 2));
        await matchesMask(image, density);
      } finally {
        image.dispose();
      }
    }
  });

  test('Flutter, desktop tiles and Apple icon resources use the supplied TED artwork', () async {
    final assets = await AssetManifest.loadFromAssetBundle(rootBundle);
    expect((await rootBundle.load('icon.png')).buffer.asUint8List(), masterBytes);
    expect(assets.listAssets().where((p) => p.contains('plezy.png') || p.contains('plezy_adaptive')), isEmpty);
    final project = await File('ios/Runner.xcodeproj/project.pbxproj').readAsString();
    final iconName = RegExp(r'ASSETCATALOG_COMPILER_APPICON_NAME = (\w+);').firstMatch(project)!.group(1)!;
    final composer = jsonDecode(await File('ios/$iconName.icon/icon.json').readAsString()) as Map;
    final layer = (composer['groups'] as List).first['layers'][0] as Map;
    expect(await File('ios/$iconName.icon/Assets/${layer['image-name']}').readAsBytes(), masterBytes);
    final catalog =
        jsonDecode(await File('macos/Assets.xcassets/AppIcon.appiconset/Contents.json').readAsString()) as Map;
    final images = [
      for (final entry in catalog['images'] as List)
        File('macos/Assets.xcassets/AppIcon.appiconset/${entry['filename']}'),
      ...Directory('windows/msix/assets').listSync().whereType<File>().where((f) => f.path.endsWith('.png')),
    ];
    for (final file in images) {
      final image = await decode(await file.readAsBytes());
      try {
        if (file.path.contains('altform-')) {
          await matchesMask(image, file.path);
        } else {
          await matchesMaster(image, file.path);
        }
      } finally {
        image.dispose();
      }
    }
  });
}
