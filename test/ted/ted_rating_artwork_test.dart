import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_rating_icon.dart';

void main() {
  for (final dimensions in [const Size(48, 48), const Size(96, 48)]) {
    testWidgets('cinema palms retain their proportions and visible space in $dimensions', (tester) async {
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox.fromSize(
                size: dimensions,
                child: const ColoredBox(color: Color(0xFF145B3A), child: TedRatingIcon(rating: 7)),
              ),
            ),
          ),
        ),
      );
      final image = (await tester.runAsync(
        () => (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 2),
      ))!;
      addTearDown(image.dispose);
      final pixels = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      var left = image.width, right = 0, top = image.height, bottom = 0, leftEnd = 0, rightStart = image.width;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final offset = (y * image.width + x) * 4;
          if (pixels.getUint8(offset) < 240 ||
              pixels.getUint8(offset + 1) < 240 ||
              pixels.getUint8(offset + 2) < 240 ||
              pixels.getUint8(offset + 3) < 240) {
            continue;
          }
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
          if (x < image.width / 2 && x > leftEnd) leftEnd = x;
          if (x >= image.width / 2 && x < rightStart) rightStart = x;
        }
      }
      final height = bottom - top + 1;
      expect(
        height,
        inInclusiveRange(image.height * .5, image.height * .7),
        reason: 'The hands leave vertical breathing room',
      );
      expect(rightStart - leftEnd - 1, greaterThan(image.height * .1), reason: 'The palms must be separated');
      expect((leftEnd - left + 1) / height, closeTo(.5, .06), reason: 'Each hand scales uniformly');
      expect((right - rightStart + 1) / height, closeTo(.5, .06));
      expect((left + right + 1) / 2, closeTo(image.width / 2, 1));
      expect((top + bottom + 1) / 2, closeTo(image.height / 2, 1));
      final evidence = Platform.environment['TED_NATIVE_LAYOUT_EVIDENCE'];
      if (evidence != null) {
        await tester.runAsync(
          () async => File(
            '$evidence/cinema-${dimensions.width.toInt()}.png',
          ).writeAsBytes((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List()),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
