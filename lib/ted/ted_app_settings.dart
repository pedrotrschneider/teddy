export 'teddy_settings_screen.dart';
import 'dart:io';
import 'package:window_manager/window_manager.dart';
import 'package:intl/date_symbol_data_local.dart';
import '../i18n/strings.g.dart';
import '../i18n/app_locale_utils.dart';
import '../services/device_performance.dart';
import '../services/fullscreen_state_manager.dart';
import '../services/gamepad_service.dart';
import '../services/macos_window_service.dart';
import '../services/native_window_service.dart';
import '../services/settings_service.dart' as prefs;
import '../utils/platform_detector.dart';
import '../utils/app_logger.dart';

/// The shared Plezy platform/preferences setup, without integration services
/// for unrelated accounts, downloads, telemetry or update checks.
Future<void> initializeTeddyPlatform(prefs.SettingsService settings) async {
  setLoggerLevel(settings.read(prefs.SettingsService.enableDebugLogging));
  await LocaleSettings.setLocale(settings.read(prefs.SettingsService.appLocale));
  await initializeDateFormatting(settings.read(prefs.SettingsService.appLocale).intlLocaleName);
  await TvDetectionService.getInstance(forceTv: settings.read(prefs.SettingsService.forceTvMode));
  await DevicePerformance.getInstance(override: settings.read(prefs.SettingsService.visualEffects));
  DevicePerformance.applyImageCacheBudget();
  if (PlatformDetector.isDesktopOS()) {
    await windowManager.ensureInitialized();
    if (Platform.isMacOS) await MacOSWindowService.setupCustomTitlebar();
  }
  NativeWindowService.initialize();
  FullscreenStateManager().startMonitoring();
  if (PlatformDetector.isDesktopOS() && settings.read(prefs.SettingsService.startInFullscreen)) {
    await FullscreenStateManager().enterFullscreen();
  }
  GamepadService.instance.start();
}
