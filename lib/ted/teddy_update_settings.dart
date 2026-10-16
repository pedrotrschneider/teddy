import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'dart:ui' show AppExitType, AppExitResponse;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/settings_service.dart';
import '../screens/settings/settings_utils.dart';
import '../widgets/setting_tile.dart';
import '../widgets/settings_section.dart';
import 'ted_version.dart';
import 'ted_app_shutdown.dart';
import 'teddy_updates.dart';
import 'teddy_update_installer.dart';

class TeddyUpdateSettings extends StatefulWidget {
  final String? downloadRoot;
  const TeddyUpdateSettings({super.key, this.downloadRoot});
  @override
  State<TeddyUpdateSettings> createState() => _TeddyUpdateSettingsState();
}

class _TeddyUpdateSettingsState extends State<TeddyUpdateSettings> {
  TeddyUpdate? _update;
  TeddyUpdateInstaller? _installer;
  TeddyPreparedUpdate? _prepared;
  bool _checking = false, _installing = false, _handedOff = false;
  String _status = '';
  double? _progress;
  int _generation = 0;
  SettingsService get _settings => SettingsService.instance;
  @override
  void initState() {
    super.initState();
    _settings.listenable(SettingsService.teddyUpdateChannel).addListener(_channelChanged);
    unawaited(_check());
  }

  void _channelChanged() {
    _installer?.cancel();
    unawaited(_check());
  }

  @override
  void dispose() {
    _generation++;
    _settings.listenable(SettingsService.teddyUpdateChannel).removeListener(_channelChanged);
    _installer?.cancel();
    if (!_handedOff && _prepared != null) unawaited(_discard(_prepared!));
    super.dispose();
  }

  Future<void> _discard(TeddyPreparedUpdate prepared) async {
    try {
      await prepared.cancel();
      await prepared.stage.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _check() async {
    if (_installing) return;
    final generation = ++_generation;
    if (_prepared != null) {
      await _discard(_prepared!);
      _prepared = null;
    }
    if (!mounted) return;
    setState(() {
      _checking = true;
      _update = null;
      _status = 'Checking for updates…';
    });
    try {
      final update = await TeddyUpdates.check(
        teddyReleaseVersion,
        _settings.read(SettingsService.teddyUpdateChannel) == 'rc',
      );
      if (mounted && generation == _generation) {
        setState(() {
          _update = update;
          _status = TeddyVersion.parse(teddyReleaseVersion) == null
              ? 'Development build: install an official release to enable updates.'
              : update == null
              ? 'You’re up to date for this compatibility major.'
              : 'Version ${update.version} is available.';
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _status = 'Could not check for updates. Please try again.');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _checking = false);
    }
  }

  Future<void> _install() async {
    if (_installing || _update == null) return;
    final shutdown = TedAppShutdownScope.maybeOf(context);
    setState(() {
      _installing = true;
      _progress = null;
      _status = 'Preparing update…';
    });
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      _installer = TeddyUpdateInstaller();
      _prepared ??= await _installer!.prepare(_update!, (status, progress) {
        if (mounted && (DateTime.now().difference(lastProgress).inMilliseconds > 100 || status != _status)) {
          lastProgress = DateTime.now();
          setState(() {
            _status = status;
            _progress = progress;
          });
        }
      });
      if (!mounted) {
        await _discard(_prepared!);
        _prepared = null;
        return;
      }
      if (!Platform.isAndroid && shutdown == null) {
        throw const TeddyUpdateFailure('Restart Teddy before installing this update.');
      }
      final target = _prepared!.target;
      if (target != null &&
          widget.downloadRoot != null &&
          (p.equals(target, widget.downloadRoot!) || p.isWithin(target, widget.downloadRoot!))) {
        throw const TeddyUpdateFailure('Move your downloads outside Teddy’s installation folder before updating.');
      }
      await _prepared!.start();
      if (Platform.isAndroid) {
        _handedOff = true;
        if (mounted) setState(() => _status = 'Confirm the update in the Android installer.');
        return;
      }
      _handedOff = true;
      if (mounted) setState(() => _status = 'Closing Teddy to install the update…');
      if (await shutdown!.requestExit() != AppExitResponse.exit) {
        await _prepared!.cancel();
        _handedOff = false;
        throw const TeddyUpdateFailure('Teddy could not finish closing its storage. Please restart and try again.');
      }
      final result = await ServicesBinding.instance.exitApplication(AppExitType.required);
      if (result == AppExitResponse.cancel) {
        await _prepared!.cancel();
        _handedOff = false;
        throw const TeddyUpdateFailure('The operating system cancelled exit. Please restart Teddy and try again.');
      }
    } catch (error) {
      if (!Platform.isAndroid && !_handedOff && _prepared != null) {
        await _discard(_prepared!);
        _prepared = null;
      }
      if (mounted) {
        setState(
          () => _status = error is TeddyUpdateFailure
              ? error.message
              : 'The update could not be installed. Your existing installation is retained. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsSectionHeader('Look for Updates'),
      SettingsGroup(
        children: [
          if (!_installing)
            SettingSelectionTile<String>(
              pref: SettingsService.teddyUpdateChannel,
              icon: Icons.update,
              title: 'Channel',
              subtitleBuilder: (v) => v == 'rc' ? 'Release Candidate' : 'Stable',
              options: const [
                DialogOption(value: 'stable', title: 'Stable'),
                DialogOption(value: 'rc', title: 'Release Candidate'),
              ],
            ),
          if (!_installing && !_checking)
            SettingNavigationTile(icon: Icons.refresh, title: 'Check for updates', onTap: _check),
          Padding(padding: const EdgeInsets.all(20), child: Text(_status)),
          if (_checking || _installing)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: LinearProgressIndicator(value: _progress),
            ),
          if (_update != null && !_installing)
            SettingNavigationTile(
              icon: Icons.system_update_alt,
              title: 'Update to version ${_update!.version}',
              subtitle: Platform.isAndroid
                  ? 'Download and open the Android installer.'
                  : 'Download, install and restart Teddy. Downloads will pause.',
              onTap: _install,
            ),
          if (_installing && !_handedOff)
            SettingNavigationTile(icon: Icons.close, title: 'Cancel download', onTap: () => _installer?.cancel()),
        ],
      ),
    ],
  );
}
