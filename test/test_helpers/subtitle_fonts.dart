import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/mpv/font_loader.dart';
import 'io_fakes.dart';

/// Font extraction uses real filesystem I/O; finish it before widget fake clocks.
Future<void> prepareSubtitleFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = PathProviderPlatform.instance;
  final root = await Directory.systemTemp.createTemp('teddy-widget-fonts-');
  PathProviderPlatform.instance = FakePathProvider(root);
  SubtitleFontLoader.resetForTesting();
  addTearDown(() async {
    SubtitleFontLoader.resetForTesting();
    PathProviderPlatform.instance = previous;
    await root.delete(recursive: true);
  });
  expect(await SubtitleFontLoader.loadSubtitleFont(), isNotNull);
}
