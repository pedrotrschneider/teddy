import 'dart:async';
import 'package:flutter/material.dart';
import 'ted_client.dart';
import 'ted_downloads.dart';
import 'ted_download_plan.dart';
import 'ted_models.dart';
import 'ted_sources.dart';
import 'ted_focus_region.dart';

Future<int?> chooseTedBulkDownloads(
  BuildContext context,
  TedDownloads downloads, {
  TedTitle? show,
  int? season,
  Set<TedMediaIdentity>? failed,
}) async {
  bool unwatched = false;
  if (failed == null) {
    final mode = await showDialog<bool>(
      context: context,
      builder: (context) => TedFocusRegion(
        autofocus: true,
        scroll: false,
        onBack: () => Navigator.of(context).pop(),
        child: AlertDialog(
          title: Text(season == null ? 'Download series' : 'Download season'),
          content: const Text('Choose which episodes to download.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Download all')),
            TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Download unwatched')),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          ],
        ),
      ),
    );
    if (mode == null || !context.mounted) return null;
    unwatched = mode;
  }
  if (!context.mounted) return null;
  return showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _BulkDownloadPicker(downloads: downloads, show: show, season: season, unwatched: unwatched, failed: failed),
  );
}

class _BulkDownloadPicker extends StatefulWidget {
  final TedDownloads downloads;
  final TedTitle? show;
  final int? season;
  final bool unwatched;
  final Set<TedMediaIdentity>? failed;
  const _BulkDownloadPicker({required this.downloads, this.show, this.season, required this.unwatched, this.failed});
  @override
  State<_BulkDownloadPicker> createState() => _BulkDownloadPickerState();
}

class _BulkDownloadPickerState extends State<_BulkDownloadPicker> {
  late final String? _owner;
  final _plan = <TedPlannedDownload>[];
  List<TedDownloadCandidate> _candidates = [];
  TedBulkSourceOptions? _options;
  TedDownloadSource? _previous;
  String? _error;
  int _index = 0, _generation = 0;
  bool _loading = true, _committing = false, _finished = false;
  bool get _valid => mounted && !_finished && widget.downloads.scope == _owner && widget.downloads.client.auth.signedIn;
  TedTitle? get _current => _index < _candidates.length ? _candidates[_index].title : null;
  @override
  void initState() {
    super.initState();
    _owner = widget.downloads.scope;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_begin()));
  }

  void _cancel() {
    if (_committing) return;
    _finished = true;
    _generation++;
    Navigator.of(context).pop();
  }

  Future<void> _begin() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_valid || _owner == null) throw const TedFailure('sign_in_required');
      if (widget.failed != null) {
        _candidates = await widget.downloads.failedCandidates(widget.failed!);
      } else {
        final titles = await widget.downloads.client.allEpisodes(widget.show!, season: widget.season);
        _candidates = await widget.downloads.downloadCandidates(titles, unwatched: widget.unwatched);
      }
      if (!mounted || _finished || gen != _generation) return;
      if (!_valid) throw const TedFailure('sign_in_required');
      if (_candidates.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No episodes need downloading.';
        });
        return;
      }
      await _advance();
    } catch (e) {
      if (mounted && !_finished && gen == _generation) {
        setState(() {
          _loading = false;
          _error = e is TedFailure ? e.message : 'The episode list could not be loaded.';
        });
      }
    }
  }

  Future<void> _advance() async {
    final gen = ++_generation;
    setState(() {
      _options = null;
      _loading = true;
      _error = null;
    });
    try {
      while (_index < _candidates.length) {
        if (!_valid) throw const TedFailure('sign_in_required');
        final options = await tedBulkSourceOptions(widget.downloads.client, _current!.media, _previous);
        if (!mounted || _finished || gen != _generation) return;
        if (!_valid) throw const TedFailure('sign_in_required');
        if (options.automatic == null) {
          setState(() {
            _options = options;
            _loading = false;
            _error = options.error?.message;
          });
          return;
        }
        _plan.add(TedPlannedDownload(_candidates[_index], options.automatic!));
        _previous = options.automatic;
        setState(() => _index++);
      }
      await _finish();
    } catch (e) {
      if (mounted && !_finished && gen == _generation) {
        setState(() {
          _loading = false;
          _error = e is TedFailure ? e.message : const TedFailure('unavailable').message;
        });
      }
    }
  }

  void _select(String value) {
    if (!_valid || _committing) return;
    if (value == 'retry') {
      unawaited(_advance());
      return;
    }
    if (value == 'skip_remaining') {
      unawaited(_finish());
      return;
    }
    if (value == 'skip') {
      _index++;
      unawaited(_advance());
      return;
    }
    try {
      final source = value == 'mapped'
          ? const TedDownloadSource.mapped()
          : TedDownloadSource.choice(_options!.page.choices.singleWhere((c) => c.id == value));
      _plan.add(TedPlannedDownload(_candidates[_index], source));
      _previous = source;
      _index++;
      unawaited(_advance());
    } on TedFailure catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _finish() async {
    if (_committing) return;
    _generation++;
    setState(() {
      _committing = true;
      _options = null;
      _loading = true;
      _error = null;
    });
    try {
      if (!_valid || _owner == null) throw const TedFailure('sign_in_required');
      final count = await widget.downloads.enqueuePlan(_owner, _plan);
      if (!mounted) return;
      _finished = true;
      Navigator.of(context).pop(count);
    } catch (e) {
      if (mounted) {
        setState(() {
          _committing = false;
          _loading = false;
          _error = e is TedFailure
              ? e.message
              : 'The download plan could not be saved. Existing downloads are retained.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final heading = current == null
        ? 'Select download sources'
        : '${current.seriesName.isEmpty ? (widget.show?.name ?? current.name) : current.seriesName} · '
              '${current.media.kind == 'movie' ? current.name : 'S${current.season ?? current.media.id.split(':')[1]} E${current.episode ?? current.media.id.split(':')[2]}'}'
              ' · ${_index + 1} of ${_candidates.length}';
    return PopScope(
      canPop: !_committing,
      child: _options != null
          ? TedSourcePicker(
              onReload: () async =>
                  (await tedBulkSourceOptions(widget.downloads.client, _current!.media, null, forceRefresh: true)).page,
              onChanged: (page) {
                if (mounted) setState(() => _options = TedBulkSourceOptions(page));
              },
              key: ValueKey(current!.media.id),
              page: _options!.page,
              client: widget.downloads.client,
              includeMapped: true,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(heading),
                  if (current.episodeName.isNotEmpty)
                    Text(current.episodeName, style: Theme.of(context).textTheme.bodyLarge),
                  if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ),
              onSelected: _select,
              onCancel: _cancel,
              actions: [
                if (_error != null || _options!.page.choices.isEmpty && !_options!.page.ready)
                  const TedSourcePickerAction('retry', 'Retry sources'),
                TedSourcePickerAction('skip', current.media.kind == 'movie' ? 'Skip movie' : 'Skip episode'),
                const TedSourcePickerAction('skip_remaining', 'Skip remaining'),
              ],
            )
          : TedFocusRegion(
              key: ValueKey('bulk-loading-$_index-$_committing'),
              autofocus: true,
              scroll: false,
              onBack: _cancel,
              child: AlertDialog(
                title: Text(heading),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_loading) const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      _error ??
                          (_committing
                              ? 'Saving the download queue…'
                              : current == null
                              ? 'Loading episodes…'
                              : 'Matching sources…'),
                    ),
                    Text('${_plan.length} selected. Transfers start when selection finishes.'),
                  ],
                ),
                actions: [
                  if (!_loading)
                    TextButton(
                      onPressed: () => unawaited(
                        _candidates.isEmpty
                            ? _begin()
                            : _index >= _candidates.length
                            ? _finish()
                            : _advance(),
                      ),
                      child: const Text('Retry'),
                    ),
                  if (current != null && !_committing)
                    TextButton(onPressed: () => _select('skip'), child: const Text('Skip episode')),
                  if (_plan.isNotEmpty && !_committing)
                    TextButton(onPressed: () => unawaited(_finish()), child: const Text('Skip remaining')),
                  TextButton(onPressed: _committing ? null : _cancel, child: const Text('Cancel')),
                ],
              ),
            ),
    );
  }
}
