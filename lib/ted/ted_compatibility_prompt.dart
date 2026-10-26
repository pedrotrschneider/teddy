import 'dart:async';

import 'package:flutter/material.dart';

import 'ted_auth.dart';
import 'ted_compatibility.dart';
import 'ted_version.dart';
import 'teddy_update_settings.dart';
import 'teddy_updates.dart';

/// Observe the connection rather than individual screens: refresh, artwork and
/// background requests can discover an incompatible server before navigation.
class TedCompatibilityPrompt extends StatefulWidget {
  final TedAuth auth;
  final String downloadRoot;
  final Widget child;
  final String currentVersion;
  final TeddyUpdateCheck checkForUpdates;
  const TedCompatibilityPrompt({
    super.key,
    required this.auth,
    required this.downloadRoot,
    required this.child,
    this.currentVersion = teddyReleaseVersion,
    this.checkForUpdates = TeddyUpdates.check,
  });

  @override
  State<TedCompatibilityPrompt> createState() => _TedCompatibilityPromptState();
}

class _TedCompatibilityPromptState extends State<TedCompatibilityPrompt> {
  DialogRoute<void>? _dialog;
  TedCompatibilityIssue? _dialogIssue, _shownIssue;
  bool _scheduled = false, _connectionChanged = false;

  @override
  void initState() {
    super.initState();
    widget.auth.compatibilityIssue.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(TedCompatibilityPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth == widget.auth) return;
    oldWidget.auth.compatibilityIssue.removeListener(_changed);
    widget.auth.compatibilityIssue.addListener(_changed);
    _shownIssue = null;
    _connectionChanged = true;
    _changed();
  }

  void _changed() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final issue = widget.auth.compatibilityIssue.value;
      if (_dialog != null && (_connectionChanged || issue != _dialogIssue)) _removeDialog();
      _connectionChanged = false;
      setState(() {});
      if (issue == null) {
        _shownIssue = null;
      } else if (issue != _shownIssue) {
        _open(issue);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _removeDialog() {
    final route = _dialog;
    _dialog = null;
    _dialogIssue = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  void _open(TedCompatibilityIssue issue, {bool update = false}) {
    if (_dialog != null) return;
    _shownIssue = issue;
    _dialogIssue = issue;
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _CompatibilityDialog(
        issue: issue,
        downloadRoot: widget.downloadRoot,
        currentVersion: widget.currentVersion,
        checkForUpdates: widget.checkForUpdates,
        update: update,
      ),
    );
    _dialog = route;
    unawaited(
      Navigator.of(context, rootNavigator: true).push(route).whenComplete(() {
        if (identical(_dialog, route)) {
          _dialog = null;
          _dialogIssue = null;
        }
      }),
    );
  }

  @override
  void dispose() {
    widget.auth.compatibilityIssue.removeListener(_changed);
    final route = _dialog;
    // Parent navigation may already hold the navigator lock during disposal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route?.isActive == true && route?.navigator?.mounted == true) route!.navigator!.removeRoute(route);
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final issue = widget.auth.compatibilityIssue.value;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (issue != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: MaterialBanner(
                content: Text(_message(issue)),
                actions: [
                  TextButton(
                    onPressed: () => _open(issue, update: issue.requiredVersion != null),
                    child: Text(issue.requiredVersion == null ? 'Details' : 'Update Teddy'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _message(TedCompatibilityIssue issue) => issue.requiredVersion == null
      ? 'TED and Teddy must use compatible versions.'
      : 'This server requires Teddy ${issue.requiredVersion!.releaseFamily}. Your app is ${widget.currentVersion}.';
}

class _CompatibilityDialog extends StatefulWidget {
  final TedCompatibilityIssue issue;
  final String downloadRoot, currentVersion;
  final TeddyUpdateCheck checkForUpdates;
  final bool update;
  const _CompatibilityDialog({
    required this.issue,
    required this.downloadRoot,
    required this.currentVersion,
    required this.checkForUpdates,
    required this.update,
  });

  @override
  State<_CompatibilityDialog> createState() => _CompatibilityDialogState();
}

class _CompatibilityDialogState extends State<_CompatibilityDialog> {
  late bool _updating = widget.update;

  @override
  Widget build(BuildContext context) {
    final required = widget.issue.requiredVersion;
    return AlertDialog(
      scrollable: true,
      title: const Text('Update required'),
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              required == null
                  ? 'TED and Teddy must use compatible versions. The server did not report a valid required version. '
                        'Reconnect to TED or ask your server administrator to check its version.'
                  : 'Your app is Teddy ${widget.currentVersion}. This server requires Teddy ${required.releaseFamily}. '
                        'Install a compatible update to connect.',
            ),
            if (_updating && required != null)
              TeddyUpdateSettings(
                requiredCompatibility: required,
                downloadRoot: widget.downloadRoot,
                currentVersion: widget.currentVersion,
                checkForUpdates: widget.checkForUpdates,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(_updating ? 'Close' : 'Later')),
        if (!_updating && required != null)
          FilledButton(
            autofocus: true,
            onPressed: () => setState(() => _updating = true),
            child: const Text('Update Teddy'),
          ),
      ],
    );
  }
}
