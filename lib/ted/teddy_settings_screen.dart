import 'teddy_update_settings.dart';
import 'ted_version.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../focus/input_mode_tracker.dart';
import '../focus/key_event_utils.dart';
import '../focus/dpad_navigator.dart';
import '../models/teddy_section.dart';
import '../screens/settings/settings_utils.dart';
import '../screens/settings/licenses_screen.dart';
import '../services/settings_service.dart' as prefs;
import '../services/settings_mutation_service.dart';
import '../services/file_picker_service.dart';
import '../services/settings_export_service.dart';
import '../utils/platform_detector.dart';
import '../utils/snackbar_helper.dart';
import '../utils/dialogs.dart';
import '../widgets/settings_page.dart';
import '../widgets/app_bar_back_button.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/settings_section.dart';
import '../widgets/setting_tile.dart';
import 'ted_downloads.dart';
import 'teddy_settings_actions.dart';
import 'teddy_logs.dart';

class TeddySettingsScreen extends StatefulWidget {
  final VoidCallback onLayoutRestart;
  final TedDownloads? downloads;
  final VoidCallback? onBackPressed, onSidebar;
  final VoidCallback? onLicenses;
  const TeddySettingsScreen({
    super.key,
    required this.onLayoutRestart,
    this.downloads,
    this.onBackPressed,
    this.onSidebar,
    this.onLicenses,
  });
  @override
  State<TeddySettingsScreen> createState() => TeddySettingsScreenState();
}

class TeddySettingsScreenState extends State<TeddySettingsScreen> {
  final _pageFocus = GlobalKey<FocusedScrollScaffoldState>();
  bool requestFocus() => _pageFocus.currentState?.requestFocus() ?? false;
  bool _changingTvMode = false, _busy = false;
  late final _info = PackageInfo.fromPlatform().catchError(
    (Object _) => PackageInfo(appName: 'Teddy', packageName: 'Teddy', version: '', buildNumber: ''),
  );
  prefs.SettingsService get settings => prefs.SettingsService.instance;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_backWithoutFocus);
    widget.downloads?.addListener(_storageChanged);
  }

  void _storageChanged() {
    if (mounted) setState(() {});
  }

  bool _backWithoutFocus(KeyEvent event) {
    // The browse shell owns lost-focus Back for embedded settings and its
    // license pages. Standalone signed-out settings retain their route fallback.
    if (widget.onBackPressed != null) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true || !event.logicalKey.isBackKey) return false;
    // The shared page handles keys within its focus tree. This fallback owns
    // only the focus-loss case; consuming it twice would pop the browse route.
    final primary = FocusManager.instance.primaryFocus;
    if (primary?.context != null && ModalRoute.of(primary!.context!) == ModalRoute.of(context)) {
      return false;
    }
    return handleBackKeyAction(event, () => Navigator.of(context).pop()) == KeyEventResult.handled;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_backWithoutFocus);
    widget.downloads?.removeListener(_storageChanged);
    super.dispose();
  }

  Future<void> _operation(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        showErrorSnackBar(
          context,
          error is SettingsExportException
              ? error.message
              : 'The operation could not finish. Your existing data is retained. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setTvMode(bool value) async {
    if (_changingTvMode) return;
    setState(() => _changingTvMode = true);
    try {
      final failure = await const SettingsMutationService().write(
        context,
        prefs.SettingsService.forceTvMode,
        value,
        rebuildRoot: false,
      );
      if (!mounted) return;
      if (failure != null) {
        showErrorSnackBar(context, failure.display);
        return;
      }
      if (value) InputModeTracker.reportNonPointerInput();
      widget.onLayoutRestart();
    } catch (_) {
      try {
        await settings.prefs.reloadCache();
      } catch (_) {}
      if (mounted) showErrorSnackBar(context, 'Could not save TV mode. Please try again.');
    } finally {
      if (mounted) setState(() => _changingTvMode = false);
    }
  }

  Future<void> _downloadPolicy(prefs.Pref<bool> pref, bool value) => _operation(() async {
    await settings.write(pref, value);
    await widget.downloads?.applyPolicies();
  });
  Future<void> _location() => _operation(() async {
    final downloads = widget.downloads;
    if (downloads == null) return;
    final selected = await FilePickerService.instance.getDirectoryPath(dialogTitle: 'Move downloads to');
    if (selected == null) return;
    await downloads.moveLocation(Directory(selected));
    if (mounted) showSuccessSnackBar(context, 'Downloads moved to ${downloads.root.path}');
  });
  Future<void> _clearCache() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Clear image cache',
      message: 'Remove cached artwork, including downloaded thumbnails. Media files and watch history are kept.',
      confirmText: 'Clear',
      isDestructive: true,
    );
    if (!confirmed) return;
    await _operation(() async {
      await widget.downloads?.clearArtwork();
      await settings.clearImageCache();
      if (mounted) widget.onLayoutRestart();
    });
  }

  Future<void> _applyRuntime() async {
    TvDetectionService.setForceTVSync(settings.read(prefs.SettingsService.forceTvMode));
    await widget.downloads?.applyPolicies();
    if (mounted) widget.onLayoutRestart();
  }

  Future<void> _reset() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Reset settings',
      message:
          'Restore every setting and move downloads to the default app-data folder. Accounts, downloads and watch history are kept.',
      confirmText: 'Reset',
      isDestructive: true,
    );
    if (!confirmed) return;
    await _operation(() async {
      final downloads = widget.downloads;
      if (downloads != null) await downloads.moveLocation(downloads.defaultRoot);
      await resetTeddySettings(settings);
      await _applyRuntime();
    });
  }

  Future<void> _export() => _operation(() async {
    final path = await SettingsExportService.exportToFile(userScope: 'teddy');
    if (mounted && path != null) showSuccessSnackBar(context, 'Settings exported to $path');
  });
  Future<void> _import() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Import settings',
      message: 'Replace matching settings from a file. Download location, accounts and watch history are kept.',
      confirmText: 'Import',
    );
    if (!confirmed) return;
    await _operation(() async {
      final result = await SettingsExportService.importFromFile(userScope: 'teddy');
      if (result == null) return;
      settings.refreshListenables();
      await _applyRuntime();
    });
  }

  Widget _switch(prefs.Pref<bool> pref, String title, IconData icon, {String? subtitle}) =>
      SettingSwitchTile(pref: pref, title: title, icon: icon, subtitle: subtitle, enabled: !_busy);
  Widget _number(prefs.Pref<int> pref, String title, IconData icon, {String unit = 'seconds'}) => SettingNumberTile(
    pref: pref,
    title: title,
    icon: icon,
    labelText: title,
    suffixText: unit,
    subtitleBuilder: (value) => '$value $unit',
  );
  Widget _marker(prefs.Pref<prefs.SkipMarkerMode> pref, String title) => SettingSelectionTile<prefs.SkipMarkerMode>(
    pref: pref,
    icon: Icons.skip_next,
    title: title,
    subtitleBuilder: (value) => switch (value) {
      prefs.SkipMarkerMode.off => 'Off',
      prefs.SkipMarkerMode.button => 'Show button',
      prefs.SkipMarkerMode.auto => 'Automatic',
    },
    options: const [
      DialogOption(value: prefs.SkipMarkerMode.off, title: 'Off', subtitle: 'Do not skip'),
      DialogOption(
        value: prefs.SkipMarkerMode.button,
        title: 'Show button',
        subtitle: 'Show a skip button for matching chapters',
      ),
      DialogOption(
        value: prefs.SkipMarkerMode.auto,
        title: 'Automatic',
        subtitle: 'Skip matching chapters after the countdown',
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    descendantsAreFocusable: !_busy,
    onKeyEvent: (_, event) {
      if (widget.onSidebar == null || event.logicalKey != LogicalKeyboardKey.arrowLeft) return KeyEventResult.ignored;
      if (event is KeyDownEvent) widget.onSidebar!();
      return KeyEventResult.handled;
    },
    child: IgnorePointer(
      ignoring: _busy,
      child: SettingsPage(
        title: const Text('Settings'),
        focusKey: _pageFocus,
        onBackPressed: widget.onBackPressed,
        focusableAppBarActions: widget.onBackPressed != null,
        leading: widget.onBackPressed == null
            ? null
            : AppBarBackButton(style: BackButtonStyle.plain, onPressed: widget.onBackPressed),
        children: [
          if (_busy) const LinearProgressIndicator(),
          const SettingsSectionHeader('General'),
          SettingsGroup(
            children: [
              SettingSelectionTile<TeddySection>(
                pref: prefs.SettingsService.teddyStartupSection,
                icon: Icons.home_outlined,
                title: 'Startup Section',
                subtitleBuilder: (value) => value.label,
                options: [
                  for (final section in TeddySection.values) DialogOption(value: section, title: section.label),
                ],
              ),
              SettingSwitchTile(
                key: const ValueKey('teddy-force-tv'),
                pref: prefs.SettingsService.forceTvMode,
                icon: Icons.tv_outlined,
                title: 'Force TV mode',
                subtitle: TvDetectionService.isAutomaticallyDetectedTV()
                    ? 'TV detected automatically. TV controls are already enabled.'
                    : 'Use TV controls on devices without automatic TV detection.',
                enabled: !_busy && !_changingTvMode,
                onWrite: _setTvMode,
              ),
              _switch(prefs.SettingsService.startInFullscreen, 'Start in fullscreen', Icons.fullscreen),
            ],
          ),
          const SettingsSectionHeader('Appearance'),
          SettingsGroup(
            children: [
              SettingSelectionTile<prefs.ThemeMode>(
                pref: prefs.SettingsService.themeMode,
                icon: Icons.palette_outlined,
                title: 'Theme',
                subtitleBuilder: themeModeLabel,
                options: [
                  for (final theme in prefs.ThemeMode.values) DialogOption(value: theme, title: themeModeLabel(theme)),
                ],
              ),
              _switch(
                prefs.SettingsService.hideSpoilers,
                'Hide spoilers for unwatched episodes',
                Icons.blur_on,
                subtitle: 'Blur episode thumbnails and descriptions, including started episodes.',
              ),
              _switch(
                prefs.SettingsService.showWatchedIndicators,
                'Show Watched Indicators',
                Icons.check_circle_outline,
              ),
              _switch(
                prefs.SettingsService.alwaysKeepSidebarOpen,
                'Always keep sidebar open',
                Icons.view_sidebar_outlined,
              ),
            ],
          ),
          const SettingsSectionHeader('Video Playback'),
          SettingsGroup(
            children: [
              _switch(prefs.SettingsService.enableHardwareDecoding, 'Hardware Decoding', Icons.memory),
              _number(prefs.SettingsService.seekTimeSmall, 'Small skip duration', Icons.replay_10),
              _number(prefs.SettingsService.seekTimeLarge, 'Large skip duration', Icons.forward_30),
              _number(prefs.SettingsService.rewindOnResume, 'Rewind on resume', Icons.replay),
              _switch(
                prefs.SettingsService.teddyAutoPlayNextEpisode,
                'Auto play next episode',
                Icons.skip_next,
                subtitle: 'At the end, continue using the same source when available.',
              ),
            ],
          ),
          const Divider(indent: 24, endIndent: 24, height: 24),
          SettingsGroup(
            children: [
              _marker(prefs.SettingsService.skipIntroMode, 'Skip intro'),
              const SettingRegexTile(
                pref: prefs.SettingsService.introPattern,
                icon: Icons.code,
                title: 'Intro marker pattern',
                subtitle: 'Match chapter names for intro skipping.',
                defaultValue: prefs.SettingsService.defaultIntroPattern,
              ),
              _marker(prefs.SettingsService.skipCreditsMode, 'Skip credits'),
              const SettingRegexTile(
                pref: prefs.SettingsService.creditsPattern,
                icon: Icons.code,
                title: 'Credits marker pattern',
                subtitle: 'Match chapter names for credits skipping.',
                defaultValue: prefs.SettingsService.defaultCreditsPattern,
              ),
            ],
          ),
          const Divider(indent: 24, endIndent: 24, height: 24),
          SettingsGroup(
            children: [
              _switch(
                prefs.SettingsService.showChapterMarkersOnTimeline,
                'Show chapter markers on seekbar',
                Icons.segment,
              ),
              _switch(
                prefs.SettingsService.clickVideoTogglesPlayback,
                'Click on video to toggle play pause',
                Icons.mouse_outlined,
              ),
              _switch(
                prefs.SettingsService.exitFullscreenOnPlayerClose,
                'Exit fullscreen on player close',
                Icons.fullscreen_exit,
              ),
            ],
          ),
          const SettingsSectionHeader('Downloads'),
          SettingsGroup(
            children: [
              SettingNavigationTile(
                icon: Icons.folder_outlined,
                title: 'Location',
                subtitle:
                    widget.downloads?.storagePhase ??
                    widget.downloads?.storageError ??
                    widget.downloads?.root.path ??
                    'Default app-data folder',
                onTap: _location,
              ),
              _number(prefs.SettingsService.teddyDownloadChunkMiB, 'Download chunk size', Icons.download, unit: 'MiB'),
              SettingNumberTile(
                pref: prefs.SettingsService.teddyMaxSimultaneousDownloads,
                title: 'Max simultaneous downloads',
                icon: Icons.downloading,
                labelText: 'Max simultaneous downloads',
                suffixText: 'downloads',
                subtitleBuilder: (value) =>
                    '$value · Applies to movies and episodes; active downloads finish when lowered.',
              ),
              SettingSwitchTile(
                pref: prefs.SettingsService.downloadOnWifiOnly,
                icon: Icons.wifi,
                title: 'Download on Wi-Fi only',
                subtitle: 'Pause downloads on a cellular-only connection.',
                enabled: !_busy,
                onWrite: (value) => _downloadPolicy(prefs.SettingsService.downloadOnWifiOnly, value),
              ),
              SettingSwitchTile(
                pref: prefs.SettingsService.autoRemoveWatchedDownloads,
                icon: Icons.auto_delete_outlined,
                title: 'Auto remove watched downloads',
                subtitle:
                    widget.downloads?.policyError ??
                    'Remove copies watched after downloading. Keep pending history sync.',
                enabled: !_busy,
                onWrite: (value) => _downloadPolicy(prefs.SettingsService.autoRemoveWatchedDownloads, value),
              ),
            ],
          ),
          const SettingsSectionHeader('Advanced'),
          SettingsGroup(
            children: [
              SettingNavigationTile(
                icon: Icons.description_outlined,
                title: 'View Logs',
                onTap: () => _operation(() async {
                  final path = await TeddyLogs.reveal();
                  if (context.mounted) showSuccessSnackBar(context, path);
                }),
              ),
              SettingNavigationTile(icon: Icons.image_outlined, title: 'Clear image cache', onTap: _clearCache),
              SettingNavigationTile(icon: Icons.restart_alt, title: 'Reset settings', onTap: _reset),
            ],
          ),
          const SettingsSectionHeader('Backup'),
          SettingsGroup(
            children: [
              SettingNavigationTile(icon: Icons.upload_file, title: 'Export settings', onTap: _export),
              SettingNavigationTile(icon: Icons.file_download_outlined, title: 'Import settings', onTap: _import),
            ],
          ),
          TeddyUpdateSettings(downloadRoot: widget.downloads?.root.path),
          const SettingsSectionHeader('About'),
          SettingsGroup(
            children: [
              FutureBuilder<PackageInfo>(
                future: _info,
                builder: (_, snapshot) => Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Teddy', style: Theme.of(context).textTheme.titleLarge),
                      if (snapshot.hasData) Text('Version $teddyReleaseVersion (${snapshot.data!.buildNumber})'),
                      const Text('The Entertainment District native client. Based on Plezy.'),
                    ],
                  ),
                ),
              ),
              SettingNavigationTile(
                icon: Icons.balance,
                title: 'Open source licenses',
                onTap: widget.onLicenses,
                destinationBuilder: (_) => const LicensesScreen(),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    ),
  );
}
