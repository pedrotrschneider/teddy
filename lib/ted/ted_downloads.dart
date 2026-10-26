import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../media/media_item.dart';
import '../mpv/mpv.dart';
import 'ted_client.dart';
import 'ted_episode_navigation.dart';
import 'ted_local_store.dart';
import 'ted_models.dart';
import 'ted_presentation.dart';
import 'ted_download_progress.dart';
import 'ted_download_watch.dart';
import 'ted_metadata_models.dart';
import 'ted_download_storage.dart';
import 'ted_download_plan.dart';
import '../services/settings_service.dart';
import '../services/connectivity_probe.dart';
import '../utils/connectivity_link_type.dart';
import '../utils/app_logger.dart';

class TedDownloadDescriptor {
  final String session, path, etag;
  final int bytes;
  final int durationMs, expectedDurationMs;
  TedDownloadDescriptor(
    this.session,
    this.path,
    this.etag,
    this.bytes, {
    this.durationMs = 0,
    this.expectedDurationMs = 0,
  });
  factory TedDownloadDescriptor.parse(Map<String, dynamic> value, String session) {
    final path = value['media_url'];
    final tag = value['etag'];
    final size = value['bytes'];
    final duration = value['duration_ms'] ?? 0, expected = value['expected_duration_ms'] ?? 0;
    if (!tedUuid(session) ||
        value['session_id'] != session ||
        path != '/api/client/v1/downloads/$session/media' ||
        tag is! String ||
        !RegExp(r'^"ted-[a-f0-9]{64}"$').hasMatch(tag) ||
        size is! int ||
        size <= 0 ||
        duration is! int ||
        duration < 0 ||
        duration > 604800000 ||
        expected is! int ||
        expected < 0 ||
        expected > 604800000) {
      throw const TedFailure('invalid_response');
    }
    return TedDownloadDescriptor(
      session,
      path as String,
      tag,
      size,
      durationMs: duration,
      expectedDurationMs: expected,
    );
  }
  void validateRange(int code, Map<String, String> headers, int start, int end, int length) {
    if (code != 206 ||
        headers['content-range'] != 'bytes $start-$end/$bytes' ||
        headers['etag'] != etag ||
        length != end - start + 1 ||
        (headers['content-encoding'] ?? 'identity') != 'identity') {
      throw const TedFailure('download_changed');
    }
  }
}

/// The pinned native downloader transfers one bounded range at a time. Only
/// the foreground auth owner renews access; no isolate reads refresh tokens.
/// Durable checkpoints are appended after validation and fsync, never before.
class TedDownloads extends ChangeNotifier {
  final TedClient client;
  final TedLocalStore store;
  Directory _root;
  Directory get root => _root;
  late final Directory defaultRoot = _root;
  Future<void>? _maintenance;
  Future<void>? _policyRun;
  String? storagePhase, storageError, policyError;
  StreamSubscription<dynamic>? _connectivity;
  final _networkPaused = <String>{};
  final Future<TaskStatusUpdate> Function(DownloadTask, void Function(double)) _transferTask;
  final Future<bool> Function(String) cancelTask;
  final Duration Function()? progressClock;
  final _clock = Stopwatch()..start();
  Timer? _progressTicker;
  final _transfers = <String, TedTransferProgress>{};
  final _rates = <String, TedDownloadRate>{};
  final _preparingMedia = <String, TedMediaIdentity>{};
  List<Map<String, dynamic>> _progressFiles = [], _progressQueue = [];
  String? _progressOwner;
  Future<void>? _progressRead;
  Future<Map<TedMediaIdentity, TedDownloadWatch>>? _watchRead;
  bool _progressAgain = false, _disposed = false;
  int storageRevision = 0;
  // Stream to a temporary file; this is not an in-memory allocation. Larger
  // ranges avoid repeating native/provider connection startup for every 8 MiB.
  // A pause/restart retries only the uncommitted range, at most 512 MiB.
  static const chunkBytes = 512 * 1024 * 1024;
  final Map<String, Future<void>> _running = {};
  final Set<String> _paused = {}, _playing = {};
  Future<void>? _shutdown;
  Future<void>? _queueRun;
  bool _queueAgain = false;
  int _downloadLimit = 1;
  ValueListenable<int>? _downloadLimitPref;
  Future<void>? _limitRead;
  Completer<void> _queueWake = Completer<void>();
  final _activeDownloads = <String>{};
  final _waitingDownloads = <String, ({bool Function() valid, Completer<bool> permit})>{};
  final _removedQueue = <String>{};
  final _queuePreparation = <String, Completer<void>>{};
  final _deleting = <TedMediaIdentity>{};
  final _removingFiles = <String>{};
  final _mediaByFile = <String, TedMediaIdentity>{};

  /// Fence all transfers first, then settle cancellation/checkpoint writes
  /// before the application closes its database.
  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    final active = _running.keys.toList();
    _paused.addAll(active);
    _shutdown = Future.wait(active.map(pause)).then((_) async {
      await _maintenance;
      await _policyRun;
      await _connectivity?.cancel();
      await _queueRun;
      await _progressRead;
      await _watchRead;
    });
    _drainDownloadSlots();
    _wakeQueue();
    return _shutdown!;
  }

  /// Invoked only for a durable explicit-Sign-Out tombstone. No active
  /// transfers remain, and only UUID directories owned by this scope are erased.
  Future<void> purgeProfile(String owner) async {
    await shutdown();
    if (storageError != null) throw const TedFailure('download_changed');
    try {
      await store.settle();
    } catch (_) {
      /* Pending reports are purged below. */
    }
    for (final row in await store.downloads(owner)) {
      final owned = directory(row['id'] as String);
      if (await owned.exists()) await owned.delete(recursive: true);
    }
    await store.purgeProfile(owner);
  }

  TedDownloads(
    this.client,
    this.store,
    Directory root, {
    Future<TaskStatusUpdate> Function(DownloadTask)? transferTask,
    Future<TaskStatusUpdate> Function(DownloadTask, void Function(double))? progressTransferTask,
    Future<bool> Function(String)? cancelTask,
    this.progressClock,
  }) : _root = root,
       _transferTask =
           progressTransferTask ??
           ((task, report) =>
               transferTask == null ? FileDownloader().download(task, onProgress: report) : transferTask(task)),
       cancelTask = cancelTask ?? FileDownloader().cancelTaskWithId;
  String? get scope => tedOfflineScope(client.auth);

  TedDownloadProgress? progress(TedMediaIdentity media, {int? season}) {
    if (_progressOwner != scope) return null;
    final now = progressClock?.call() ?? _clock.elapsed;
    final current = {
      for (final entry in _transfers.entries)
        entry.key: TedTransferProgress(entry.value.received, _rates[entry.key]?.bytesPerSecond(now)),
    };
    return TedDownloadProgress.select(
      _progressFiles,
      _progressQueue,
      current,
      _preparingMedia.values.toSet(),
      media,
      season: season,
    );
  }

  /// One shared durable projection for folder rows and all detail buttons.
  /// Native progress callbacks update only transient display bytes/speed.
  Future<void> refreshProgress() {
    if (_disposed || _shutdown != null) return Future.value();
    _progressAgain = true;
    return _progressRead ??= (() async {
      do {
        _progressAgain = false;
        final owner = scope;
        try {
          final files = await list(), queue = await queueEntries();
          if (!_disposed && owner == scope) {
            _progressOwner = owner;
            _progressFiles = files;
            _progressQueue = queue;
            super.notifyListeners();
          }
        } catch (_) {
          // Downloads performs its own actionable storage read; retain the
          // last usable projection instead of claiming an empty queue.
          if (!_disposed) super.notifyListeners();
        }
      } while (_progressAgain && !_disposed && _shutdown == null);
    })().whenComplete(() => _progressRead = null);
  }

  void _changed() {
    storageRevision++;
    unawaited(refreshProgress());
  }

  @override
  void dispose() {
    _disposed = true;
    _downloadLimitPref?.removeListener(_limitChanged);
    _drainDownloadSlots();
    _wakeQueue();
    _progressTicker?.cancel();
    _clock.stop();
    super.dispose();
  }

  Future<TedEpisodeTargets> offlineTargets(TedMediaIdentity media) async {
    if (media.kind != 'episode') return const TedEpisodeTargets();
    final tuple = media.id.split(':');
    final files = await list();
    final current = files
        .where((row) => TedMediaIdentity.fromJson(Map<String, dynamic>.from(row['media'] as Map)) == media)
        .firstOrNull;
    final currentItem = current == null ? null : metadata(current);
    final currentSeason = currentItem?.parentIndex ?? int.parse(tuple[1]),
        currentEpisode = currentItem?.index ?? int.parse(tuple[2]);
    final titles = <TedTitle>[];
    for (final file in files) {
      final identity = TedMediaIdentity.fromJson(Map<String, dynamic>.from(file['media'] as Map));
      if (file['status'] != 'complete' || identity.kind != 'episode') continue;
      final parts = identity.id.split(':');
      final item = metadata(file);
      final season = item.parentIndex ?? int.parse(parts[1]), episode = item.index ?? int.parse(parts[2]);
      if (parts.first != tuple.first || (season == 0) != (currentSeason == 0)) continue;
      final path = p.join(directory(file['id'] as String).path, 'media.bin');
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file ||
          await File(path).length() != file['bytes']) {
        continue;
      }
      titles.add(
        TedTitle(
          identity,
          item.title ?? identity.id,
          '',
          false,
          file['watch_revision'] as int,
          file['resume_ms'] as int,
          true,
          ready: true,
          season: season,
          episode: episode,
        ),
      );
    }
    titles.sort((a, b) => a.season == b.season ? a.episode!.compareTo(b.episode!) : a.season!.compareTo(b.season!));
    bool before(TedTitle title) =>
        title.season! < currentSeason || title.season == currentSeason && title.episode! < currentEpisode;
    bool after(TedTitle title) =>
        title.season! > currentSeason || title.season == currentSeason && title.episode! > currentEpisode;
    return TedEpisodeTargets(previous: titles.where(before).lastOrNull, next: titles.where(after).firstOrNull);
  }

  Future<List<Map<String, dynamic>>> list() async {
    final rows = scope == null ? <Map<String, dynamic>>[] : await store.downloads(scope!);
    for (final row in rows) {
      _validateSaved(row);
      _mediaByFile[row['id'] as String] = TedMediaIdentity.fromJson(Map<String, dynamic>.from(row['media'] as Map));
      if (_waitingDownloads.containsKey(row['id'])) {
        row['status'] = 'queued';
        row.remove('error');
      }
    }
    return rows;
  }

  Future<Map<TedMediaIdentity, TedDownloadWatch>> watchStates(List<Map<String, dynamic>> files) {
    if (_shutdown != null) return Future.value({});
    return _watchRead ??= _readWatchStates(files).whenComplete(() => _watchRead = null);
  }

  Future<Map<TedMediaIdentity, TedDownloadWatch>> _readWatchStates(List<Map<String, dynamic>> files) async {
    final owner = scope;
    if (owner == null) return {};
    final result = <TedMediaIdentity, TedDownloadWatch>{};
    for (final value in files) {
      _validateSaved(value);
      if (value['scope'] != owner) throw const TedFailure('sign_in_required');
      if (value['status'] == 'complete' && value['downloaded_at'] == null) {
        final path = p.join(directory(value['id'] as String).path, 'media.bin');
        if (await FileSystemEntity.type(path, followLinks: false) == FileSystemEntityType.file) {
          final stat = await File(path).stat();
          if (stat.size == value['bytes']) {
            // Existing real copies predate this field. Retain their final file
            // modification boundary once; never use today's cache-read time.
            value['downloaded_at'] = stat.modified.toUtc().toIso8601String();
            await store.saveDownload(owner, value);
          }
        }
      }
      final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(value['media'] as Map));
      final position = value['resume_ms'] as int? ?? 0, duration = value['duration_ms'] as int? ?? 0;
      result[media] = value['download_watch'] == null
          ? TedDownloadWatch(
              media,
              false,
              position > 0 && (duration <= 0 || position * 100 < duration * 95),
              position,
              duration > 0 ? duration : null,
              null,
              null,
            )
          : TedDownloadWatch.fromJson(Map<String, dynamic>.from(value['download_watch'] as Map));
      if (result[media]!.media != media) throw const TedFailure('invalid_response');
    }
    var fresh = false;
    if (client.auth.signedIn && result.isNotEmpty) {
      try {
        final ids = result.keys.toList(), fetched = <TedMediaIdentity, TedDownloadWatch>{};
        for (var i = 0; i < ids.length; i += 200) {
          if (scope != owner || _shutdown != null) return {};
          fetched.addAll(await client.downloadWatches(ids.sublist(i, min(i + 200, ids.length))));
        }
        if (scope != owner || _shutdown != null) return {};
        for (final value in files) {
          final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(value['media'] as Map));
          await store.cacheDownloadWatch(owner, value['id'] as String, fetched[media]!.toJson());
        }
        result.addAll(fetched);
        fresh = true;
      } on TedFailure {
        // Retain the last successful account projection during an outage.
      }
    }
    if (!fresh) {
      for (final entry in result.entries.toList()) {
        if (scope != owner || _shutdown != null) return {};
        result[entry.key] = entry.value.withLocal(
          await store.lastPosition(owner, entry.key),
          entry.value.durationMs ?? 0,
        );
      }
    }
    return scope == owner ? result : {};
  }

  // Recovery data is untrusted input too. Never forward a bearer token to an
  // absolute saved URL or use stored asset keys/codecs as filesystem paths.
  void _validateSaved(Map<String, dynamic> v) {
    directory(v['id'] as String);
    TedDownloadDescriptor.parse({
      'session_id': v['session'],
      'media_url': v['url'],
      'bytes': v['bytes'],
      'etag': v['etag'],
      'duration_ms': v['duration_ms'],
      'expected_duration_ms': v['expected_duration_ms'],
    }, v['session'] as String);
    if (!TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map)).playable ||
        v['received'] is! int ||
        (v['received'] as int) < 0 ||
        (v['received'] as int) > (v['bytes'] as int)) {
      throw const TedFailure('invalid_response');
    }
    final images = Map<String, dynamic>.from(v['images'] as Map);
    final original = v['original_language'];
    if (original != null &&
        (original is! String || (original.isNotEmpty && !RegExp(r'^[a-z]{2,3}$').hasMatch(original)))) {
      throw const TedFailure('invalid_response');
    }
    if (v['downloaded_at'] != null &&
        (v['downloaded_at'] is! String || DateTime.tryParse(v['downloaded_at'] as String) == null)) {
      throw const TedFailure('invalid_response');
    }
    if (images.keys.any((key) => !['poster', 'background', 'logo', 'show', 'thumbnail'].contains(key)) ||
        images.values.any((value) => value is! String)) {
      throw const TedFailure('invalid_response');
    }
    final subs = v['subtitles'] as List;
    if (subs.length > 64) throw const TedFailure('invalid_response');
    for (final raw in subs) {
      TedSubtitle.fromJson(Map<String, dynamic>.from(raw as Map), v['session'] as String);
    }
  }

  Directory directory(String id) {
    if (!tedUuid(id)) throw const TedFailure('invalid_response');
    final dir = Directory(p.join(root.path, id));
    for (final path in [root.path, dir.path]) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.directory && type != FileSystemEntityType.notFound) {
        throw const TedFailure('download_changed');
      }
    }
    return dir;
  }

  Future<void> recover() async {
    final storage = TedDownloadStorage(store, defaultRoot);
    _root = await storage.root();
    await root.create(recursive: true);
    // Tasks belong to this UUID namespace only. A killed app may leave a
    // completed native chunk; without its validated receipt it is discarded.
    final rows = await store.allDownloads();
    for (final v in rows) {
      _validateSaved(v);
      final id = v['id'] as String;
      await cancelTask('teddy-$id');
      final chunk = File(p.join(directory(id).path, 'chunk'));
      if (await chunk.exists()) await chunk.delete();
      if (v['status'] == 'downloading') {
        v['status'] = 'paused';
        await store.saveDownload(v['scope'] as String, v);
      }
    }
    try {
      await storage.resume();
    } catch (_) {
      storageError = 'A download move is unfinished. Open Settings → Location to retry it.';
    }
    _root = await storage.root();
  }

  Future<void> moveLocation(Directory destination) {
    if (_maintenance != null || _playing.isNotEmpty || _removingFiles.isNotEmpty || _deleting.isNotEmpty) {
      return Future.error(const TedFailure('download_in_use'));
    }
    final active = _running.keys.where((id) => !_paused.contains(id)).toList();
    _paused.addAll(active);
    storagePhase = 'Pausing transfers';
    storageError = null;
    notifyListeners();
    final moving = _maintenance = (() async {
      try {
        await Future.wait(active.map(pause));
        await _queueRun;
        await _policyRun;
        await _progressRead;
        await _watchRead;
        final rows = await store.allDownloads();
        for (final row in rows) {
          _validateSaved(row);
          // Uncommitted native ranges are not checkpoints. Do not put them in
          // a move manifest that startup recovery intentionally discards.
          final chunk = File(p.join(directory(row['id'] as String).path, 'chunk'));
          if (await FileSystemEntity.type(chunk.path, followLinks: false) == FileSystemEntityType.file) {
            await chunk.delete();
          }
        }
        final storage = TedDownloadStorage(
          store,
          defaultRoot,
          progress: (phase) {
            storagePhase = phase;
            if (!_disposed) notifyListeners();
          },
        );
        await storage.move(destination, rows.map((v) => v['id'] as String).toList());
        _root = await storage.root();
      } catch (_) {
        _root = await TedDownloadStorage(store, defaultRoot).root();
        storageError = 'Download move could not finish. Files are retained; choose the same location to retry.';
        rethrow;
      } finally {
        storagePhase = null;
        _maintenance = null;
        _changed();
      }
      for (final row in await list()) {
        if (active.contains(row['id']) && row['status'] != 'complete') unawaited(resume(row));
      }
      pumpQueue();
    })();
    _drainDownloadSlots();
    _wakeQueue();
    return moving;
  }

  Future<void> clearArtwork() async {
    if (_maintenance != null || _running.isNotEmpty) throw const TedFailure('download_in_use');
    final finished = Completer<void>();
    _maintenance = finished.future;
    try {
      for (final row in await store.allDownloads()) {
        _validateSaved(row);
        for (final name in ['poster', 'thumbnail', 'show', 'season', 'background', 'logo']) {
          final file = File(p.join(directory(row['id'] as String).path, '$name.image'));
          if (await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.file) {
            await file.delete();
          }
        }
      }
      _changed();
    } finally {
      _maintenance = null;
      finished.complete();
    }
  }

  void startPolicies() {
    _connectivity ??= ConnectivityProbe.changes.listen((_) => unawaited(applyPolicies().catchError((Object _) {})));
  }

  Future<void> applyPolicies() => _policyRun ??= _applyPolicies()
      .then(
        (_) {
          policyError = null;
        },
        onError: (Object error, StackTrace stack) {
          policyError = 'Download settings could not be applied. Check your download location and try again.';
          appLogger.w('Teddy download policy could not finish');
          if (!_disposed) notifyListeners();
          Error.throwWithStackTrace(error, stack);
        },
      )
      .whenComplete(() => _policyRun = null);

  Future<void> _applyPolicies() async {
    if (_shutdown != null || _maintenance != null) return;
    final settings = await SettingsService.getInstance();
    final blocked =
        settings.read(SettingsService.downloadOnWifiOnly) && (await ConnectivityProbe.check()).isCellularOnly;
    if (_shutdown != null || _maintenance != null) return;
    if (blocked) {
      final active = _running.keys.where((id) => !_paused.contains(id)).toList();
      _networkPaused.addAll(active);
      await Future.wait(active.map((id) => pause(id, userRequested: false)));
    } else {
      for (final row in await list()) {
        if (_networkPaused.remove(row['id']) && row['status'] != 'complete') unawaited(resume(row));
      }
      pumpQueue();
    }
    if (!settings.read(SettingsService.autoRemoveWatchedDownloads)) return;
    // While online, wait for receipts before using TED's current projection.
    // Offline local completion remains sufficient and its immutable outbox is
    // independent of file removal.
    final owner = scope;
    if (owner == null || client.auth.signedIn && await store.pending(owner) > 0) return;
    final files = (await list()).where((row) => row['status'] == 'complete').toList();
    final watches = await watchStates(files);
    if (_shutdown != null || _maintenance != null || scope != owner) return;
    for (final file in files) {
      final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(file['media'] as Map));
      final at = DateTime.tryParse(file['downloaded_at'] as String? ?? '');
      if (_playing.contains(file['id']) || watches[media]?.watchedAfter(at) != true) continue;
      await remove(file);
    }
  }

  Future<void> add(TedTitle title, TedPlaybackSession session, {bool autoStart = true}) async {
    if (_shutdown != null || _maintenance != null) throw const TedFailure('download_paused');
    final owner = scope;
    if (owner == null) throw const TedFailure('sign_in_required');
    final values = await store.downloads(owner);
    if (values.any((v) => jsonEncode(v['media']) == jsonEncode(title.media.toJson()))) {
      throw const TedFailure('download_exists');
    }
    final value = await _prepareDownload(title, session, const Uuid().v4(), owner);
    if (scope != owner) throw const TedFailure('sign_in_required');
    if (_deleting.contains(title.media)) throw const TedFailure('download_paused');
    await store.saveDownload(owner, value);
    _changed();
    if (autoStart) unawaited(resume(value));
  }

  Future<Map<String, dynamic>> _prepareDownload(
    TedTitle title,
    TedPlaybackSession session,
    String id,
    String owner,
  ) async {
    if (session.media != title.media) throw const TedFailure('invalid_response');
    final data = await client.auth.json('POST', '/api/client/v1/downloads/resolve', body: {'session_id': session.id});
    final d = TedDownloadDescriptor.parse(data, session.id);
    if (scope != owner) throw const TedFailure('sign_in_required');
    if (_deleting.contains(title.media)) throw const TedFailure('download_paused');
    final value = <String, dynamic>{
      'id': id,
      'scope': owner,
      'media': title.media.toJson(),
      'session': session.id,
      'url': d.path,
      'etag': d.etag,
      'bytes': d.bytes,
      'received': 0,
      'status': 'paused',
      'duration_ms': d.durationMs > 0 ? d.durationMs : session.durationMs,
      'expected_duration_ms': d.expectedDurationMs > 0 ? d.expectedDurationMs : session.expectedDurationMs,
      'resume_ms': session.resumeMs,
      'watch_revision': session.watchRevision,
      'audio_languages': session.audioLanguages,
      'original_language': session.originalLanguage,
      'metadata': TedPresentation(client).item(title).toJson(),
      'images': {
        'poster': title.episodePoster.isNotEmpty ? title.episodePoster : title.poster,
        if (title.media.kind == 'episode') 'thumbnail': title.episodePoster,
        'background': title.background,
        'logo': title.logo,
        if (title.media.kind == 'episode') 'show': title.poster,
      },
      'subtitles': [
        for (final s in session.subtitles) {'url': s.path, 'language': s.language, 'label': s.label, 'codec': s.codec},
      ],
    };
    _validateSaved(value);
    return value;
  }

  Future<List<TedDownloadCandidate>> downloadCandidates(
    List<TedTitle> titles, {
    bool unwatched = false,
    bool failedOnly = false,
  }) async {
    final owner = scope;
    if (owner == null || !client.auth.signedIn) throw const TedFailure('sign_in_required');
    final files = await list(), queued = await queueEntries();
    if (scope != owner) throw const TedFailure('sign_in_required');
    final result = <TedDownloadCandidate>[];
    for (final title in [...titles]..sort(tedEpisodeDownloadOrder)) {
      final file = files
          .where((v) => TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map)) == title.media)
          .firstOrNull;
      final queue = queued
          .where((v) => TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map)) == title.media)
          .firstOrNull;
      final failed = file?['status'] == 'failed' || queue?['status'] == 'failed';
      if (failedOnly && !failed ||
          unwatched && title.played ||
          file != null && file['status'] != 'failed' && queue?['status'] != 'failed' ||
          file?['status'] == 'complete' ||
          queue != null &&
              queue['status'] != 'failed' &&
              !(queue['status'] == 'paused' && file?['status'] == 'failed')) {
        continue;
      }
      result.add(
        TedDownloadCandidate(
          title,
          fileId: file?['id'] as String?,
          fileSession: file?['session'] as String?,
          queueId: queue?['id'] as String?,
        ),
      );
    }
    return result;
  }

  Future<Set<TedMediaIdentity>> failedDownloads(Set<TedMediaIdentity> selection) async {
    final owner = scope;
    final files = await list(), queued = await queueEntries();
    if (scope != owner) throw const TedFailure('sign_in_required');
    return {
      for (final row in [...files, ...queued])
        if (row['status'] == 'failed') TedMediaIdentity.fromJson(Map<String, dynamic>.from(row['media'] as Map)),
    }..retainAll(selection);
  }

  Future<List<TedDownloadCandidate>> failedCandidates(Set<TedMediaIdentity> selection) async {
    final owner = scope;
    if (owner == null || !client.auth.signedIn) throw const TedFailure('sign_in_required');
    final failed = await failedDownloads(selection);
    final files = await list(), queue = await queueEntries();
    if (scope != owner) throw const TedFailure('sign_in_required');
    final titles = <TedTitle>[];
    for (final media in failed) {
      final row =
          files
              .where((v) => TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map)) == media)
              .firstOrNull ??
          queue.firstWhere((v) => TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map)) == media);
      final raw = row['metadata'];
      final item = raw == null ? null : MediaItem.fromJson(Map<String, dynamic>.from(raw as Map));
      titles.add(
        TedTitle(
          media,
          row['name'] as String? ?? item?.title ?? media.id,
          '',
          false,
          0,
          0,
          false,
          seriesName: item?.grandparentTitle ?? '',
          episodeName: media.kind == 'episode' ? item?.title ?? '' : '',
          parent: media.kind == 'episode' ? TedMediaIdentity('series', media.id.split(':').first) : null,
          season: media.kind == 'episode' ? item?.parentIndex ?? int.parse(media.id.split(':')[1]) : null,
          episode: media.kind == 'episode' ? item?.index ?? int.parse(media.id.split(':')[2]) : null,
        ),
      );
    }
    return downloadCandidates(titles, failedOnly: true);
  }

  Future<int> enqueuePlan(String owner, List<TedPlannedDownload> plan) async {
    if (plan.isEmpty) return 0;
    bool valid() =>
        scope == owner &&
        client.auth.signedIn &&
        _shutdown == null &&
        _maintenance == null &&
        plan.every(
          (p) =>
              !_deleting.contains(p.candidate.title.media) &&
              !_running.containsKey(p.candidate.fileId) &&
              !_playing.contains(p.candidate.fileId),
        );
    if (!valid()) throw const TedFailure('download_in_use');
    if (plan.length > 10000 || plan.map((p) => p.candidate.title.media).toSet().length != plan.length) {
      throw const TedFailure('invalid_response');
    }
    final entries = [
      for (final p in plan)
        {
          'id': const Uuid().v4(),
          'scope': owner,
          'media': p.candidate.title.media.toJson(),
          'name': p.candidate.title.name,
          'metadata': TedPresentation(client).item(p.candidate.title).toJson(),
          'status': 'queued',
          'selected_source': p.source.toJson(),
          'expected_queue': p.candidate.queueId,
          if (p.candidate.fileId != null)
            'replace_download': {'id': p.candidate.fileId, 'session': p.candidate.fileSession},
        },
    ];
    for (final p in plan) {
      p.source.validate();
      if (!p.candidate.title.media.playable || !p.candidate.title.media.valid) {
        throw const TedFailure('invalid_response');
      }
    }
    await store.saveDownloadPlan(owner, entries, valid);
    _changed();
    pumpQueue();
    return plan.length;
  }

  Future<void> retryFailed(Set<TedMediaIdentity> selection) async {
    final owner = scope;
    if (owner == null || !client.auth.signedIn) throw const TedFailure('sign_in_required');
    final files = await list(), queued = await queueEntries();
    final entries = <Map<String, dynamic>>[];
    for (final media in selection) {
      final q = queued
          .where((v) => TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map)) == media)
          .firstOrNull;
      final file = files
          .where((v) => TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map)) == media)
          .firstOrNull;
      if (q != null && (q['status'] == 'failed' || q['status'] == 'paused' && file?['status'] == 'failed')) {
        entries.add(
          Map<String, dynamic>.from(q)
            ..['status'] = 'queued'
            ..remove('error'),
        );
      } else if (q == null && file?['status'] == 'failed') {
        entries.add({
          'id': const Uuid().v4(),
          'scope': owner,
          'media': media.toJson(),
          'name': metadata(file!).title ?? media.id,
          'metadata': file['metadata'],
          'status': 'queued',
        });
      }
    }
    await store.retryDownloadEntries(
      owner,
      entries,
      () => scope == owner && client.auth.signedIn && _shutdown == null && _maintenance == null,
    );
    _changed();
    pumpQueue();
  }

  Future<List<Map<String, dynamic>>> queueEntries() async {
    final owner = scope;
    if (owner == null) return [];
    final values = await store.queuedDownloads(owner);
    for (final v in values) {
      final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map));
      if (!tedUuid(v['id'] as String) ||
          v['scope'] != owner ||
          !media.playable ||
          v['name'] is! String ||
          !['queued', 'failed', 'paused'].contains(v['status'])) {
        throw const TedFailure('invalid_response');
      }
      if (v['selected_source'] != null) {
        TedDownloadSource.fromJson(Map<String, dynamic>.from(v['selected_source'] as Map));
      }
      if (v['replace_download'] != null) {
        final replace = v['replace_download'] as Map;
        if (!tedUuid(replace['id'] as String) || !tedUuid(replace['session'] as String)) {
          throw const TedFailure('invalid_response');
        }
      }
      if (v['replacement'] != null) {
        final replacement = Map<String, dynamic>.from(v['replacement'] as Map);
        _validateSaved(replacement);
        if (replacement['scope'] != owner ||
            TedMediaIdentity.fromJson(Map<String, dynamic>.from(replacement['media'] as Map)) != media ||
            replacement['id'] != (v['replace_download'] as Map?)?['id']) {
          throw const TedFailure('invalid_response');
        }
      }
    }
    return values;
  }

  Future<void> _configureDownloadLimit() => _limitRead ??= (() async {
    final settings = await SettingsService.getInstance();
    if (_disposed || _shutdown != null) return;
    _downloadLimitPref ??= settings.listenable(SettingsService.teddyMaxSimultaneousDownloads)
      ..addListener(_limitChanged);
    _limitChanged();
  })();

  void _wakeQueue() {
    final previous = _queueWake;
    _queueWake = Completer<void>();
    previous.complete();
  }

  void _limitChanged() {
    _downloadLimit = _downloadLimitPref?.value ?? 1;
    _drainDownloadSlots();
    _wakeQueue();
  }

  void _drainDownloadSlots() {
    // Admission and reservation are synchronous, so concurrent resumes share
    // one cap. Lowering the cap never interrupts an already reserved copy.
    for (final entry in _waitingDownloads.entries.toList()) {
      if (!entry.value.valid()) {
        _waitingDownloads.remove(entry.key);
        entry.value.permit.complete(false);
      } else if (_activeDownloads.length < _downloadLimit) {
        _waitingDownloads.remove(entry.key);
        _activeDownloads.add(entry.key);
        entry.value.permit.complete(true);
      }
    }
  }

  Future<void> _limitedTransfer(Map<String, dynamic> value) async {
    await _configureDownloadLimit();
    final id = value['id'] as String;
    final permit = Completer<bool>();
    bool valid() =>
        !_disposed &&
        _shutdown == null &&
        _maintenance == null &&
        scope == value['scope'] &&
        !_paused.contains(id) &&
        !_removingFiles.contains(id);
    _waitingDownloads[id] = (valid: valid, permit: permit);
    _drainDownloadSlots();
    _changed();
    if (!await permit.future) return;
    try {
      if (valid()) await _transfer(value);
    } finally {
      _activeDownloads.remove(id);
      _drainDownloadSlots();
      _wakeQueue();
    }
  }

  void pumpQueue() {
    if (_shutdown != null || _maintenance != null || !client.auth.signedIn) return;
    if (_queueRun != null) {
      _queueAgain = true;
      _wakeQueue();
      return;
    }
    final owner = scope;
    if (owner == null) return;
    _queueRun = _runQueue(owner)
        .catchError((Object _) {
          /* Preserve unreadable queue state; Downloads exposes the read error. */
        })
        .whenComplete(() {
          _queueRun = null;
          _changed();
          if (_queueAgain) {
            _queueAgain = false;
            pumpQueue();
          }
        });
  }

  Future<void> retryQueued(Map<String, dynamic> entry) async {
    if (entry['scope'] != scope) throw const TedFailure('sign_in_required');
    final value = Map<String, dynamic>.from(entry)
      ..['status'] = 'queued'
      ..remove('error');
    await store.saveQueuedDownload(scope!, value);
    _changed();
    pumpQueue();
  }

  Future<void> resumeDownload(Map<String, dynamic> saved) async {
    final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(saved['media'] as Map));
    final queued = (await queueEntries())
        .where((v) => TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map)) == media)
        .firstOrNull;
    if (queued != null) {
      await retryQueued(queued);
    } else {
      await resume(saved);
    }
  }

  Future<void> removeQueued(Map<String, dynamic> entry) async {
    if (entry['scope'] != scope) throw const TedFailure('sign_in_required');
    final id = entry['id'] as String;
    _removedQueue.add(id);
    final existing = (await list()).where((v) => jsonEncode(v['media']) == jsonEncode(entry['media'])).firstOrNull;
    if (existing != null) await remove(existing);
    await store.deleteQueuedDownload(scope!, id);
    _changed();
  }

  Future<TedPlaybackSession> _queuedSession(Map<String, dynamic> entry, TedMediaIdentity media) async {
    final raw = entry['selected_source'];
    if (raw == null) {
      // Recover already-persisted queues created before interactive planning.
      final sources = await client.sources(media);
      if (sources.mapped && !sources.ready) throw const TedFailure('mapping_not_ready');
      final source = sources.mapped ? null : sources.choices.firstOrNull?.id;
      if (!sources.mapped && source == null) throw const TedFailure('no_supported_sources');
      return client.createSession(media, sourceId: source);
    }
    final selected = TedDownloadSource.fromJson(Map<String, dynamic>.from(raw as Map));
    if (selected.provider == 'mapped') {
      final page = await client.mappedSource(media);
      if (!page.mapped || !page.ready) throw const TedFailure('mapping_not_ready');
      return client.createSession(media);
    }
    final page = await client.stremioSources(media, preferredAddonId: selected.addonId);
    final source = selected.match(page);
    if (source == null) throw const TedFailure('source_selection_required');
    return client.createSession(media, sourceId: source.id);
  }

  Future<Map<String, dynamic>> _replaceQueuedDownload(
    Map<String, dynamic> entry,
    Map<String, dynamic> saved,
    TedMediaIdentity media,
    String owner,
    bool Function() valid,
  ) async {
    final expected = entry['replace_download'] as Map;
    if (saved['id'] != expected['id']) throw const TedFailure('download_changed');
    Map<String, dynamic>? replacement = entry['replacement'] == null
        ? null
        : Map<String, dynamic>.from(entry['replacement'] as Map);
    if (replacement == null) {
      if (saved['session'] != expected['session'] || saved['status'] == 'complete') {
        throw const TedFailure('download_changed');
      }
      final title = await client.title(media);
      if (!valid()) throw const TedFailure('download_paused');
      final session = await _queuedSession(entry, media);
      if (!valid()) throw const TedFailure('download_paused');
      if (session.id == expected['session']) throw const TedFailure('download_changed');
      replacement = await _prepareDownload(title, session, saved['id'] as String, owner);
      if (!valid()) throw const TedFailure('download_paused');
      // Durable intent precedes resetting owned failed bytes. A restart uses
      // this exact prepared descriptor, never a fresh heuristic selection.
      entry['replacement'] = replacement;
      await store.saveQueuedDownload(owner, entry);
    }
    _validateSaved(replacement);
    if (saved['session'] != replacement['session']) {
      if (saved['session'] != expected['session'] ||
          saved['status'] == 'complete' ||
          _playing.contains(saved['id']) ||
          _running.containsKey(saved['id'])) {
        throw const TedFailure('download_in_use');
      }
      final id = saved['id'] as String;
      if (!_removingFiles.add(id)) throw const TedFailure('download_in_use');
      try {
        await pause(id);
        if (!valid()) throw const TedFailure('download_paused');
        final dir = directory(id);
        if (await dir.exists()) await dir.delete(recursive: true);
        if (!valid()) throw const TedFailure('download_paused');
        await store.saveDownload(owner, replacement);
        saved = replacement;
      } finally {
        _removingFiles.remove(id);
      }
    }
    entry.remove('replacement');
    entry.remove('replace_download');
    await store.saveQueuedDownload(owner, entry);
    return saved;
  }

  Future<void> _runQueue(String owner) async {
    await _configureDownloadLimit();
    final jobs = <String, Future<void>>{};
    try {
      while (!_disposed && _shutdown == null && _maintenance == null && scope == owner && client.auth.signedIn) {
        final wake = _queueWake.future;
        final busy = jobs.keys.toSet();
        final entries = await queueEntries();
        if (_disposed || _shutdown != null || _maintenance != null || scope != owner || !client.auth.signedIn) break;
        for (final entry in entries) {
          if (jobs.length >= _downloadLimit) break;
          final id = entry['id'] as String;
          // A job can finish while this SQL snapshot is in flight. Its stale
          // queued row must not start again; the next read sees its receipt.
          if (entry['status'] != 'queued' || busy.contains(id) || jobs.containsKey(id) || _removedQueue.contains(id)) {
            continue;
          }
          jobs[id] = _runQueuedEntry(entry, owner).whenComplete(() {
            jobs.remove(id);
            _wakeQueue();
          });
        }
        if (jobs.isEmpty) return;
        await Future.any<void>([...jobs.values, wake]);
      }
    } finally {
      // Shutdown, moves, account switches and queue read failures settle every
      // held preparation/transfer before their owner may close storage.
      _drainDownloadSlots();
      await Future.wait(jobs.values.toList());
    }
  }

  Future<void> _runQueuedEntry(Map<String, dynamic> entry, String owner) async {
    final id = entry['id'] as String;
    final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(entry['media'] as Map));
    final preparing = Completer<void>();
    _queuePreparation[id] = preparing;
    bool valid() =>
        !_disposed &&
        _shutdown == null &&
        _maintenance == null &&
        scope == owner &&
        client.auth.signedIn &&
        !_removedQueue.contains(id) &&
        !_deleting.contains(media);
    try {
      _preparingMedia[id] = media;
      _changed();
      var saved = (await store.downloads(
        owner,
      )).where((v) => jsonEncode(v['media']) == jsonEncode(entry['media'])).firstOrNull;
      if (saved != null && entry['replace_download'] != null) {
        saved = await _replaceQueuedDownload(entry, saved, media, owner, valid);
        if (!valid()) return;
      }
      if (saved == null && entry['replace_download'] != null) throw const TedFailure('download_changed');
      if (saved == null) {
        final title = await client.title(media);
        if (!valid()) return;
        final session = await _queuedSession(entry, media);
        if (!valid()) return;
        await add(title, session, autoStart: false);
        if (!valid()) return;
        saved = (await store.downloads(owner)).firstWhere((v) => jsonEncode(v['media']) == jsonEncode(entry['media']));
      }
      if (saved['status'] != 'complete') {
        _preparingMedia.remove(id);
        await resume(saved);
        if (!valid()) return;
        final savedID = saved['id'];
        saved = (await store.downloads(owner)).where((v) => v['id'] == savedID).firstOrNull;
      }
      if (saved == null) {
        await store.deleteQueuedDownload(owner, id);
        return;
      }
      if (saved['status'] != 'complete') {
        final value = Map<String, dynamic>.from(entry)
          ..['status'] = _paused.contains(saved['id']) || saved['status'] == 'paused' ? 'paused' : 'failed'
          ..['error'] = _paused.contains(saved['id']) ? 'download_paused' : saved['error'] ?? 'download_unavailable';
        await store.saveQueuedDownload(owner, value);
      } else {
        await store.deleteQueuedDownload(owner, id);
      }
    } catch (e) {
      if (!valid()) return;
      final value = Map<String, dynamic>.from(entry)
        ..['status'] = 'failed'
        ..['error'] = e is TedFailure ? e.code : 'download_unavailable';
      await store.saveQueuedDownload(owner, value);
    } finally {
      _queuePreparation.remove(id);
      _preparingMedia.remove(id);
      preparing.complete();
    }
    _changed();
  }

  Future<void> resume(Map<String, dynamic> saved) {
    if (_shutdown != null || _maintenance != null) return Future.error(const TedFailure('download_paused'));
    final id = saved['id'] as String;
    if (_running.containsKey(id)) return _running[id]!;
    _paused.remove(id);
    late final Future<void> op;
    op = _limitedTransfer(Map.from(saved)).whenComplete(() {
      _running.remove(id);
      _transfers.remove(id);
      _rates.remove(id);
      if (_running.isEmpty) {
        _progressTicker?.cancel();
        _progressTicker = null;
      }
      _changed();
    });
    _running[id] = op;
    _progressTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_disposed) super.notifyListeners();
    });
    return op;
  }

  Future<void> _transfer(Map<String, dynamic> v) async {
    _validateSaved(v);
    final id = v['id'] as String, owner = v['scope'] as String;
    final dir = directory(id);
    final partial = File(p.join(dir.path, 'media.partial')), finalFile = File(p.join(dir.path, 'media.bin'));
    final d = TedDownloadDescriptor(v['session'] as String, v['url'] as String, v['etag'] as String, v['bytes'] as int);
    Future<void> persist() async {
      await store.saveDownload(owner, v);
      _changed();
    }

    void fence() {
      if (scope != owner || _paused.contains(id)) throw const TedFailure('download_paused');
    }

    try {
      fence();
      await dir.create(recursive: true);
      // Recover rename-before-database-commit without redownloading or deleting.
      if (await finalFile.exists() && v['received'] == d.bytes && await finalFile.length() == d.bytes) {
        v['downloaded_at'] ??= (await finalFile.stat()).modified.toUtc().toIso8601String();
        v['status'] = 'complete';
        await persist();
        return;
      }
      if (await finalFile.exists()) throw const TedFailure('download_changed');
      final received = v['received'] as int;
      if (received < 0 || received > d.bytes || (received > 0 && !await partial.exists())) {
        throw const TedFailure('download_changed');
      }
      if (await partial.exists() && await partial.length() < received) throw const TedFailure('download_changed');
      final file = await partial.open(mode: FileMode.append);
      try {
        await file.truncate(received);
        await file.setPosition(received);
        _rates[id] = TedDownloadRate(received, progressClock?.call() ?? _clock.elapsed);
        v['status'] = 'downloading';
        v.remove('error');
        await persist();
        while ((v['received'] as int) < d.bytes) {
          fence();
          final settings = await SettingsService.getInstance();
          if (settings.read(SettingsService.downloadOnWifiOnly) && (await ConnectivityProbe.check()).isCellularOnly) {
            _networkPaused.add(id);
            throw const TedFailure('download_paused');
          }
          fence();
          final size = settings.read(SettingsService.teddyDownloadChunkMiB) * 1024 * 1024;
          final start = v['received'] as int, end = min(start + size - 1, d.bytes - 1);
          final chunk = File(p.join(dir.path, 'chunk'));
          if (await chunk.exists()) await chunk.delete();
          var headers = await client.auth.headers();
          fence();
          Future<TaskStatusUpdate> transfer() async {
            var reporting = true, lastReceived = start;
            final began = progressClock?.call() ?? _clock.elapsed;
            var lastTime = began;
            try {
              return await _transferTask(
                DownloadTask(
                  taskId: 'teddy-$id',
                  url: client.auth.server!.resolve(d.path).toString(),
                  headers: {
                    ...headers,
                    'Range': 'bytes=$start-$end',
                    'If-Match': d.etag,
                    'Accept-Encoding': 'identity',
                  },
                  filename: 'chunk',
                  directory: dir.path,
                  baseDirectory: BaseDirectory.root,
                  requiresWiFi: settings.read(SettingsService.downloadOnWifiOnly),
                  group: 'teddy',
                  retries: 0,
                  allowPause: false,
                ),
                (progress) {
                  if (!reporting ||
                      _disposed ||
                      scope != owner ||
                      _paused.contains(id) ||
                      !progress.isFinite ||
                      progress < 0 ||
                      progress > 1) {
                    return;
                  }
                  final now = progressClock?.call() ?? _clock.elapsed;
                  final received = start + ((end - start + 1) * progress).floor();
                  final elapsed = (now - lastTime).inMicroseconds;
                  if (received <= lastReceived || elapsed < 250000 && progress < 1) return;
                  _rates[id]!.record(received, now);
                  _transfers[id] = TedTransferProgress(received, null);
                  lastReceived = received;
                  lastTime = now;
                  super.notifyListeners();
                },
              );
            } finally {
              reporting = false; // ignore late native callbacks, including a failed auth attempt
            }
          }

          var result = await transfer();
          fence();
          if (result.responseStatusCode == 401) {
            final current = await client.auth.headers();
            if (current['Authorization'] == headers['Authorization']) await client.auth.refresh();
            headers = await client.auth.headers();
            fence();
            if (await chunk.exists()) await chunk.delete();
            result = await transfer();
            fence();
          }
          if (result.status != TaskStatus.complete) {
            throw TedFailure(result.responseStatusCode == 409 ? 'download_changed' : 'download_failed');
          }
          d.validateRange(
            result.responseStatusCode ?? 0,
            result.responseHeaders ?? {},
            start,
            end,
            await chunk.length(),
          );
          await for (final bytes in chunk.openRead()) {
            fence();
            await file.writeFrom(bytes);
          }
          await file.flush();
          fence();
          v['received'] = end + 1;
          await persist();
          await chunk.delete();
        }
      } finally {
        await file.close();
      }
      fence();
      // Assets are original bounded bytes. Metadata is already durable; failed
      // sidecars/artwork remain visible and retryable instead of vanishing.
      await _assets(v);
      fence();
      // Persist the publication boundary before rename so rename-before-commit
      // recovery retains it. Completion/artwork retries must never move it.
      v['downloaded_at'] = DateTime.now().toUtc().toIso8601String();
      await persist();
      fence();
      await partial.rename(finalFile.path);
      v['status'] = 'complete';
      await persist();
    } on TedFailure catch (e) {
      _transfers.remove(id);
      v['status'] = e.code == 'download_paused' ? 'paused' : 'failed';
      v['error'] = e.code;
      await persist();
    } catch (_) {
      _transfers.remove(id);
      v['status'] = 'failed';
      v['error'] = 'download_failed';
      await persist();
    }
  }

  Future<void> _assets(Map<String, dynamic> v) async {
    _validateSaved(v);
    if (_shutdown != null || scope != v['scope']) return;
    if ((v['original_language'] as String? ?? '').isEmpty) {
      try {
        final owner = v['scope'];
        final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map));
        final language = await client.originalLanguage(
          media,
          current: () => _shutdown == null && scope == owner && !_deleting.contains(media),
        );
        if (_shutdown == null && scope == owner && !_deleting.contains(media)) v['original_language'] = language;
      } catch (_) {
        /* Retain a completed playable copy when metadata is unavailable. */
      }
    }

    final dir = directory(v['id'] as String), owner = v['scope'] as String;
    final images = Map<String, dynamic>.from(v['images'] as Map);
    final subtitles = (v['subtitles'] as List).cast<Map>();
    final missing = <String>[];
    Future<void> fetch(String url, String filename, bool authenticated, int limit) async {
      final target = File(p.join(dir.path, filename));
      if (await target.exists()) return;
      if (scope != owner || _paused.contains(v['id'])) throw const TedFailure('download_paused');
      final uri = authenticated ? client.auth.offlineServer!.resolve(url) : Uri.parse(url);
      if (!['https', 'http'].contains(uri.scheme)) throw const TedFailure('download_failed');
      final request = http.Request('GET', uri);
      request.followRedirects = !authenticated;
      if (authenticated) request.headers.addAll(await client.auth.headers());
      var response = await client.auth.client.send(request).timeout(const Duration(seconds: 20));
      if (authenticated && response.statusCode == 401) {
        await response.stream.drain<void>().timeout(const Duration(seconds: 20));
        final current = await client.auth.headers();
        if (current['Authorization'] == request.headers['Authorization']) await client.auth.refresh();
        final retry = http.Request('GET', uri);
        retry.followRedirects = false;
        retry.headers.addAll(await client.auth.headers());
        if (scope != owner) throw const TedFailure('download_paused');
        response = await client.auth.client.send(retry).timeout(const Duration(seconds: 20));
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>().timeout(const Duration(seconds: 20));
        throw const TedFailure('download_failed');
      }
      final bytes = <int>[];
      await for (final part in response.stream.timeout(const Duration(seconds: 20))) {
        if (_paused.contains(v['id']) || scope != owner) throw const TedFailure('download_paused');
        if (bytes.length + part.length > limit) throw const TedFailure('download_failed');
        bytes.addAll(part);
      }
      if (scope != owner) throw const TedFailure('download_paused');
      final temp = File('${target.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
    }

    Future<void> retain(String url, String filename, bool authenticated, int limit) async {
      try {
        await fetch(url, filename, authenticated, limit);
      } on TedFailure catch (e) {
        if (e.code == 'download_paused') rethrow;
        missing.add(filename);
      } catch (_) {
        missing.add(filename);
      }
    }

    for (final entry in images.entries) {
      if (entry.value is String && (entry.value as String).isNotEmpty) {
        await retain(entry.value as String, '${entry.key}.image', false, 20 * 1024 * 1024);
      }
    }
    for (var i = 0; i < subtitles.length; i++) {
      await retain(subtitles[i]['url'] as String, 'sub-$i.${subtitles[i]['codec']}', true, 8 * 1024 * 1024);
    }
    final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map));
    if (media.kind == 'episode') {
      bool valid() => scope == owner && !_paused.contains(v['id']) && _shutdown == null && !_deleting.contains(media);
      try {
        final cached = await _cacheArtwork(
          v,
          'thumbnail',
          () async => (await client.title(media)).enrichment,
          valid,
          wait: false,
        );
        if (!valid()) throw const TedFailure('download_paused');
        if (!cached) missing.add('thumbnail.image');
      } on TedFailure catch (e) {
        if (e.code == 'download_paused') rethrow;
        missing.add('thumbnail.image');
      } catch (_) {
        missing.add('thumbnail.image');
      }
    }
    v['missing_assets'] = missing;
  }

  Future<bool> _cacheArtwork(
    Map<String, dynamic> value,
    String name,
    Future<TedMetadataSnapshot?> Function() load,
    bool Function() valid, {
    bool wait = true,
  }) async {
    final target = File(p.join(directory(value['id'] as String).path, '$name.image'));
    if (!valid()) return false;
    if (await target.exists()) return true;
    var snapshot = await load();
    for (var attempt = 0; valid() && snapshot != null && attempt < (wait ? 12 : 1); attempt++) {
      final asset = snapshot.images.where((v) => v.type == 'Primary').firstOrNull;
      final bytes = asset == null ? null : await client.metadataImage(asset.id);
      if (!valid()) return false;
      if (bytes != null) {
        final temp = File('${target.path}.tmp');
        await temp.writeAsBytes(bytes, flush: true);
        if (!valid()) {
          await temp.delete();
          return false;
        }
        await temp.rename(target.path);
        return true;
      }
      if (!wait || !snapshot.pending && (asset == null || asset.status == 'failed')) return false;
      await Future<void>.delayed(const Duration(seconds: 1));
      if (valid()) snapshot = await client.metadata(snapshot.id);
    }
    return false;
  }

  Future<void> retryAssets(Map<String, dynamic> saved) {
    if (_shutdown != null || _maintenance != null) return Future.error(const TedFailure('download_paused'));
    final id = saved['id'] as String;
    if (_running.containsKey(id)) return _running[id]!;
    _paused.remove(id);
    late final Future<void> work;
    work =
        (() async {
          if (scope != saved['scope'] || saved['status'] != 'complete') throw const TedFailure('sign_in_required');
          final value = Map<String, dynamic>.from(saved);
          await _assets(value);
          await store.saveDownload(value['scope'] as String, value);
        })().whenComplete(() {
          _running.remove(id);
          _changed();
        });
    _running[id] = work;
    return work;
  }

  Future<void> pause(String id, {bool userRequested = true}) async {
    final owner = scope, waiting = _waitingDownloads.containsKey(id);
    if (userRequested) _networkPaused.remove(id);
    _paused.add(id);
    _drainDownloadSlots();
    _wakeQueue();
    await cancelTask('teddy-$id');
    try {
      await _running[id];
    } on TedFailure catch (e) {
      if (e.code != 'download_paused') rethrow;
    }
    if (waiting && owner != null && scope == owner) {
      await store.pauseWaitingDownload(owner, id);
      _changed();
    }
  }

  Future<void> remove(Map<String, dynamic> value) async {
    if (_maintenance != null) throw const TedFailure('download_in_use');
    final id = value['id'] as String;
    if (_playing.contains(id)) throw const TedFailure('download_in_use');
    if (!_removingFiles.add(id)) throw const TedFailure('download_in_use');
    try {
      final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(value['media'] as Map));
      final queued = (await queueEntries())
          .where((v) => TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map)) == media)
          .toList();
      _removedQueue.addAll(queued.map((v) => v['id'] as String));
      await pause(id);
      if (scope != value['scope']) throw const TedFailure('sign_in_required');
      if (await directory(id).exists()) await directory(id).delete(recursive: true);
      await store.deleteDownload(scope!, id);
      for (final entry in queued) {
        await store.deleteQueuedDownload(scope!, entry['id'] as String);
      }
    } finally {
      _removingFiles.remove(id);
      _changed();
    }
  }

  /// Fence the whole selection before awaiting any transfer or provider call.
  /// If any selected file is playing, leave every sibling and queue intent.
  Future<void> removeSelection(Set<TedMediaIdentity> media) async {
    if (_maintenance != null) throw const TedFailure('download_in_use');
    final owner = scope;
    if (owner == null) throw const TedFailure('sign_in_required');
    final rows = (await list())
        .where((v) => media.contains(TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map))))
        .toList();
    final queued = (await queueEntries())
        .where((v) => media.contains(TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map))))
        .toList();
    if (scope != owner) throw const TedFailure('sign_in_required');
    if (rows.any((v) => _playing.contains(v['id']))) throw const TedFailure('download_in_use');
    if (media.any(_deleting.contains)) throw const TedFailure('download_in_use');
    _deleting.addAll(media);
    _removedQueue.addAll(queued.map((v) => v['id'] as String));
    final preparing = queued.map((v) => _queuePreparation[v['id']]?.future).whereType<Future<void>>().toList();
    try {
      await Future.wait(rows.map((v) => pause(v['id'] as String)));
      await Future.wait(preparing);
      if (scope != owner) throw const TedFailure('sign_in_required');
      // A preparation already committing a descriptor may have added a row.
      final settled = (await list())
          .where((v) => media.contains(TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map))))
          .toList();
      for (final row in settled) {
        await remove(row);
      }
      for (final entry in queued) {
        if (scope != owner) throw const TedFailure('sign_in_required');
        await store.deleteQueuedDownload(owner, entry['id'] as String);
      }
    } finally {
      _deleting.removeAll(media);
      _changed();
      pumpQueue();
    }
  }

  Future<int> diskBytes(Map<String, dynamic> value) async {
    _validateSaved(value);
    var bytes = 0;
    final names = [
      'media.bin',
      'media.partial',
      'poster.image',
      'thumbnail.image',
      'show.image',
      'season.image',
      'background.image',
      'logo.image',
      for (var i = 0; i < (value['subtitles'] as List).length; i++) 'sub-$i.${value['subtitles'][i]['codec']}',
    ];
    for (final name in names) {
      final path = p.join(directory(value['id'] as String).path, name);
      if (await FileSystemEntity.type(path, followLinks: false) == FileSystemEntityType.file) {
        bytes += (await File(path).stat()).size;
      }
    }
    return bytes;
  }

  /// Cache episode/season artwork in the same owned download directory for offline
  /// folder presentation. This work shares removal/shutdown fencing.
  Future<void> cacheFolderArtwork(Map<String, dynamic> saved) {
    final id = saved['id'] as String;
    if (_shutdown != null ||
        _maintenance != null ||
        !client.auth.signedIn ||
        saved['status'] != 'complete' ||
        _running.containsKey(id)) {
      return Future.value();
    }
    final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(saved['media'] as Map));
    if (_deleting.contains(media)) return Future.value();
    final dir = directory(id);
    final folderArtwork =
        media.kind == 'episode' &&
        !(File(p.join(dir.path, 'season.image')).existsSync() &&
            File(p.join(dir.path, 'show.image')).existsSync() &&
            File(p.join(dir.path, 'thumbnail.image')).existsSync());
    final missingArtwork = (saved['images'] as Map).entries.any(
      (entry) => (entry.value as String).isNotEmpty && !File(p.join(dir.path, '${entry.key}.image')).existsSync(),
    );
    if (!folderArtwork && !missingArtwork && (saved['original_language'] as String? ?? '').isNotEmpty) {
      return Future.value();
    }
    _paused.remove(id);
    bool valid() => scope == saved['scope'] && !_paused.contains(id) && _shutdown == null && !_deleting.contains(media);
    late Future<void> work;
    work =
        (() async {
          final value = Map<String, dynamic>.from(saved);
          if (!valid()) return;
          if (media.kind == 'episode') {
            final images = Map<String, dynamic>.from(value['images'] as Map);
            images['show'] = metadata(value).grandparentThumbPath ?? '';
            value['images'] = images;
          }
          await _assets(value);
          if (!valid()) return;
          if (media.kind != 'episode') {
            await store.saveDownload(value['scope'] as String, value);
            return;
          }
          final thumbnail = await _cacheArtwork(
            value,
            'thumbnail',
            () async => (await client.title(media)).enrichment,
            valid,
          );
          final parts = media.id.split(':');
          await _cacheArtwork(
            value,
            'season',
            () => client.season(parts.first, metadata(value).parentIndex ?? int.parse(parts[1])),
            valid,
          );
          if (!valid()) return;
          if (thumbnail) (value['missing_assets'] as List).remove('thumbnail.image');
          await store.saveDownload(value['scope'] as String, value);
        })().whenComplete(() {
          _running.remove(id);
          _changed();
        });
    _running[id] = work;
    return work;
  }

  Future<TedPlaybackSession> offlineSession(Map<String, dynamic> v) async {
    _validateSaved(v);
    if (scope != v['scope'] || v['status'] != 'complete') throw const TedFailure('sign_in_required');
    final media = TedMediaIdentity.fromJson(Map<String, dynamic>.from(v['media'] as Map));
    _mediaByFile[v['id'] as String] = media;
    final last = await store.lastPosition(scope!, media);
    var position = (last?['position_ms'] ?? v['resume_ms']) as int;
    final duration = (last?['duration_ms'] ?? v['duration_ms']) as int;
    if (last?['kind'] == 'complete' || (duration > 0 && position * 100 >= duration * 95)) position = 0;
    final file = File(p.join(directory(v['id'] as String).path, 'media.bin'));
    if (!await file.exists() || await file.length() != v['bytes']) throw const TedFailure('download_changed');
    return TedPlaybackSession(
      const Uuid().v4(),
      media,
      file.path,
      duration,
      position,
      expectedDurationMs: v['expected_duration_ms'] as int? ?? 0,
      watchRevision: v['watch_revision'] as int,
      downloadSourceSession: v['session'] as String,
      audioLanguages: (v['audio_languages'] as List).cast<String>(),
      originalLanguage: v['original_language'] as String? ?? '',
    );
  }

  MediaItem metadata(Map<String, dynamic> v) => MediaItem.fromJson(Map<String, dynamic>.from(v['metadata'] as Map));
  List<SubtitleTrack> sidecarTracks(Map<String, dynamic> v) => [
    for (var i = 0; i < (v['subtitles'] as List).length; i++)
      if (File(p.join(directory(v['id'] as String).path, 'sub-$i.${v['subtitles'][i]['codec']}')).existsSync())
        SubtitleTrack.uri(
          p.join(directory(v['id'] as String).path, 'sub-$i.${v['subtitles'][i]['codec']}'),
          title: v['subtitles'][i]['label'] as String,
          language: v['subtitles'][i]['language'] as String,
          codec: v['subtitles'][i]['codec'] as String,
        ),
  ];
  void beginPlaying(String id) {
    if (_maintenance != null || _removingFiles.contains(id) || _deleting.contains(_mediaByFile[id])) {
      throw const TedFailure('download_in_use');
    }
    _playing.add(id);
  }

  void endPlaying(String id) {
    _playing.remove(id);
  }
}
