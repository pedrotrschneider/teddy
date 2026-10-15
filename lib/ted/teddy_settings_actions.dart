import '../services/settings_service.dart';

/// The native client's reset surface. Credentials, device identity, journals,
/// file records and device-local language/source choices are not settings.
const teddySettings = <Pref<Object?>>[
  SettingsService.teddyStartupSection,
  SettingsService.forceTvMode,
  SettingsService.startInFullscreen,
  SettingsService.themeMode,
  SettingsService.hideSpoilers,
  SettingsService.showWatchedIndicators,
  SettingsService.alwaysKeepSidebarOpen,
  SettingsService.enableHardwareDecoding,
  SettingsService.seekTimeSmall,
  SettingsService.seekTimeLarge,
  SettingsService.rewindOnResume,
  SettingsService.teddyAutoPlayNextEpisode,
  SettingsService.skipIntroMode,
  SettingsService.introPattern,
  SettingsService.skipCreditsMode,
  SettingsService.creditsPattern,
  SettingsService.showChapterMarkersOnTimeline,
  SettingsService.clickVideoTogglesPlayback,
  SettingsService.exitFullscreenOnPlayerClose,
  SettingsService.downloadOnWifiOnly,
  SettingsService.autoRemoveWatchedDownloads,
];

Future<void> resetTeddySettings(SettingsService settings) async {
  // Include saved portable choices from earlier UI versions and imports too,
  // including the marker patterns Plezy's historical reset deliberately kept.
  final values = {...SettingsService.portablePrefs, ...teddySettings, SettingsService.teddyDownloadChunkMiB}.toList();
  final before = {for (final pref in values) pref: settings.read(pref)};
  try {
    for (final pref in values) {
      await settings.write(pref, pref.resolvedDefault);
    }
  } catch (_) {
    // Restore confirmed values on failure; reload rather than pretending a
    // failed platform save rolled back its in-memory cache.
    try {
      for (final entry in before.entries) {
        await settings.write(entry.key, entry.value);
      }
    } finally {
      await settings.prefs.reloadCache();
      settings.refreshListenables();
    }
    rethrow;
  }
}
