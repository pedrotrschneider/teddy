import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';
import 'ted_auth.dart';
import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_season_source.dart';
import 'ted_track_languages.dart';

String? tedOfflineScope(TedAuth auth) =>
    auth.offlineServer == null || auth.offlineUserId == null || auth.deviceId == null
    ? null
    : jsonEncode([auth.offlineServer.toString(), auth.offlineUserId, auth.deviceId]);

/// One device journal. Persistence precedes delivery and exact envelopes survive
/// lost acknowledgments, restart and a new login by the same account/device.
class TedLocalStore {
  final AppDatabase db;
  Future<void> _writes = Future.value();
  Future<void>? _upload;
  Future<void>? _close;
  bool _closing = false;
  TedLocalStore(this.db);

  Future<void> settle() async {
    await _upload;
    await _writes;
  }

  /// Explicit Sign Out is the owner's exception to durable report retention.
  /// Files are removed first; a secure-store tombstone makes this retryable.
  Future<void> purgeProfile(String scope) => _serial(
    () => db.transaction(() async {
      await db.customStatement(
        'DELETE FROM ted_reports WHERE session_id IN (SELECT id FROM ted_sessions WHERE scope=?)',
        [scope],
      );
      for (final table in [
        'ted_sessions',
        'ted_downloads',
        'ted_download_queue',
        'ted_season_sources',
        'ted_track_languages',
        'ted_source_cache',
        'ted_home_cache',
      ]) {
        await db.customStatement('DELETE FROM $table WHERE scope=?', [scope]);
      }
    }),
  );

  Future<Map<String, dynamic>?> downloadStorage() async {
    final row = await db
        .customSelect("SELECT value FROM ted_installation WHERE key='download_storage'")
        .getSingleOrNull();
    return row == null ? null : Map<String, dynamic>.from(jsonDecode(row.read<String>('value')) as Map);
  }

  Future<void> saveDownloadStorage(Map<String, dynamic> value) => _serial(
    () => db.customStatement(
      "INSERT INTO ted_installation(key,value) VALUES('download_storage',?) "
      'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [jsonEncode(value)],
    ),
  );

  Future<TedTrackLanguages> trackLanguages(String scope, TedMediaIdentity media) async {
    final row = await db
        .customSelect(
          'SELECT audio,subtitle FROM ted_track_languages WHERE scope=? AND title=?',
          variables: [Variable(scope), Variable(tedLanguageTitle(media))],
        )
        .getSingleOrNull();
    return row == null
        ? const TedTrackLanguages()
        : TedTrackLanguages(audio: row.read<String>('audio'), subtitle: row.read<String>('subtitle'));
  }

  Future<void> rememberTrackLanguage(String scope, TedMediaIdentity media, String language, {required bool audio}) =>
      _serial(() async {
        final normalized = tedLanguage(language);
        if (normalized.isEmpty) return;
        final field = audio ? 'audio' : 'subtitle';
        await db.customStatement(
          'INSERT INTO ted_track_languages(scope,title,$field) VALUES(?,?,?) '
          'ON CONFLICT(scope,title) DO UPDATE SET $field=excluded.$field',
          [scope, tedLanguageTitle(media), normalized],
        );
      });

  Future<TedSeasonSource?> seasonSource(String scope, TedMediaIdentity media) async {
    if (media.kind != 'episode' || !media.valid) return null;
    final tuple = media.id.split(':');
    final row = await db
        .customSelect(
          'SELECT value FROM ted_season_sources WHERE scope=? AND show_id=? AND season=?',
          variables: [Variable(scope), Variable(tuple.first), Variable(int.parse(tuple[1]))],
        )
        .getSingleOrNull();
    return row == null ? null : TedSeasonSource.fromJson(jsonDecode(row.read<String>('value')) as Map<String, dynamic>);
  }

  Future<void> rememberSeasonSource(String scope, TedPlaybackSession session) => _serial(() async {
    if (session.media.kind != 'episode' || !session.media.valid) return;
    final tuple = session.media.id.split(':');
    await db.customStatement(
      'INSERT INTO ted_season_sources(scope,show_id,season,value) VALUES(?,?,?,?) '
      'ON CONFLICT(scope,show_id,season) DO UPDATE SET value=excluded.value',
      [scope, tuple.first, int.parse(tuple[1]), jsonEncode(TedSeasonSource.fromSession(session).toJson())],
    );
  });

  /// Network delivery may remain pending, but accepted local writes must finish
  /// before the SQLite connection and its background isolate are destroyed.
  Future<void> close() {
    _closing = true;
    return _close ??= (() async {
      try {
        await _upload;
      } catch (_) {
        // Failed/uncertain delivery keeps the exact envelopes for next launch.
      }
      await _writes;
      await db.close();
    })();
  }

  Future<String> installationDevice() => _serial(
    () => db.transaction(() async {
      final row = await db.customSelect("SELECT value FROM ted_installation WHERE key='device'").getSingleOrNull();
      if (row != null) {
        final id = row.read<String>('value');
        if (!tedUuid(id)) throw const TedFailure('invalid_response');
        return id;
      }
      final id = const Uuid().v4();
      await db.customStatement("INSERT INTO ted_installation(key,value) VALUES('device',?)", [id]);
      return id;
    }),
  );
  Future<void> retainDevice(String id) => _serial(() async {
    if (!tedUuid(id)) throw const TedFailure('invalid_response');
    await db.customStatement(
      "INSERT INTO ted_installation(key,value) VALUES('device',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      [id],
    );
  });

  Future<T> _serial<T>(Future<T> Function() work) {
    if (_closing) return Future.error(StateError('Device storage is closing'));
    final next = _writes.then((_) => work());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> record(String scope, TedPlaybackSession session, Map<String, dynamic> event, {bool offline = false}) =>
      _serial(
        () => db.transaction(() async {
          final existing = await db
              .customSelect('SELECT * FROM ted_sessions WHERE id=?', variables: [Variable(session.id)])
              .getSingleOrNull();
          if (existing != null && existing.read<String>('scope') != scope) throw const TedFailure('sign_in_required');
          if (existing == null) {
            String? registration;
            if (offline) {
              final previous = await db
                  .customSelect(
                    'SELECT id FROM ted_sessions WHERE scope=? AND media=? AND closed=1 ORDER BY rowid DESC LIMIT 1',
                    variables: [Variable(scope), Variable(jsonEncode(session.media.toJson()))],
                  )
                  .getSingleOrNull();
              registration = jsonEncode({
                'id': session.id,
                'media': session.media.toJson(),
                'watch_revision': session.watchRevision,
                'started_at': event['observed_at'],
                if (session.downloadSourceSession.isNotEmpty) 'source_session': session.downloadSourceSession,
                if (previous != null) 'previous_session': previous.read<String>('id'),
              });
            }
            await db.customStatement('INSERT INTO ted_sessions(id,scope,media,registration) VALUES(?,?,?,?)', [
              session.id,
              scope,
              jsonEncode(session.media.toJson()),
              registration,
            ]);
          }
          final encoded = jsonEncode(event);
          await db.customStatement('INSERT INTO ted_reports(id,session_id,envelope) VALUES(?,?,?)', [
            event['id'],
            session.id,
            encoded,
          ]);
          final duration = (event['duration_ms'] as int?) ?? 0;
          final qualified =
              existing?.read<int>('qualified') == 1 ||
              event['kind'] == 'complete' ||
              duration > 0 && (event['position_ms'] as int) * 100 >= duration * 15 ||
              duration == 0 && event['natural_eof'] == true;
          await db.customStatement('UPDATE ted_sessions SET last_event=?,closed=?,qualified=? WHERE id=?', [
            encoded,
            event['kind'] == 'stop' || event['kind'] == 'complete' ? 1 : 0,
            qualified ? 1 : 0,
            session.id,
          ]);
        }),
      );

  /// Interrupted viewing ends at the last observed offset/time, never at EOF.
  /// This closes ordering for a subsequent offline session after process death.
  Future<void> recoverInterrupted() => _serial(
    () => db.transaction(() async {
      final rows = await db
          .customSelect('SELECT id,last_event FROM ted_sessions WHERE closed=0 AND last_event IS NOT NULL')
          .get();
      for (final row in rows) {
        final e = Map<String, dynamic>.from(jsonDecode(row.read<String>('last_event')) as Map);
        e['id'] = const Uuid().v4();
        e['sequence'] = (e['sequence'] as int) + 1;
        e['kind'] = 'stop';
        e['natural_eof'] = false;
        final raw = jsonEncode(e);
        await db.customStatement('INSERT INTO ted_reports(id,session_id,envelope) VALUES(?,?,?)', [
          e['id'],
          row.read<String>('id'),
          raw,
        ]);
        await db.customStatement('UPDATE ted_sessions SET last_event=?,closed=1 WHERE id=?', [
          raw,
          row.read<String>('id'),
        ]);
      }
    }),
  );

  Future<int> pending(String scope) async =>
      (await db
              .customSelect(
                'SELECT count(*) AS n FROM ted_reports r JOIN ted_sessions s ON s.id=r.session_id WHERE s.scope=?',
                variables: [Variable(scope)],
              )
              .getSingle())
          .read<int>('n');

  Future<void> flush(TedClient client, String scope) {
    if (_closing) return Future.error(StateError('Device storage is closing'));
    if (_upload != null) return _upload!;
    late final Future<void> operation;
    operation =
        (() async {
          await _writes;
          while (true) {
            if (tedOfflineScope(client.auth) != scope || !client.auth.signedIn) {
              throw const TedFailure('sign_in_required');
            }
            final rows = await db
                .customSelect(
                  '''SELECT r.id,r.envelope,s.registration FROM ted_reports r JOIN ted_sessions s ON s.id=r.session_id
          WHERE s.scope=? ORDER BY r.ordinal LIMIT 20''',
                  variables: [Variable(scope)],
                )
                .get();
            if (rows.isEmpty) return;
            final events = rows
                .map((r) => Map<String, dynamic>.from(jsonDecode(r.read<String>('envelope')) as Map))
                .toList();
            final registrations = <String, Map<String, dynamic>>{};
            for (final r in rows) {
              final raw = r.readNullable<String>('registration');
              if (raw != null) {
                final value = Map<String, dynamic>.from(jsonDecode(raw) as Map);
                registrations[value['id'] as String] = value;
              }
            }
            await client.events(events, sessions: registrations.values.toList());
            // A partial/invalid response never reaches here; successful receipts are
            // committed together. Deletion failure simply retries identical UUIDs.
            await _serial(
              () => db.transaction(() async {
                for (final r in rows) {
                  await db.customStatement('DELETE FROM ted_reports WHERE id=?', [r.read<String>('id')]);
                }
              }),
            );
          }
        })().whenComplete(() {
          if (identical(_upload, operation)) _upload = null;
        });
    _upload = operation;
    return operation;
  }

  Future<Map<String, dynamic>?> lastPosition(String scope, TedMediaIdentity media) async {
    final row = await db
        .customSelect(
          'SELECT last_event FROM ted_sessions WHERE scope=? AND media=? AND qualified=1 AND last_event IS NOT NULL ORDER BY rowid DESC LIMIT 1',
          variables: [Variable(scope), Variable(jsonEncode(media.toJson()))],
        )
        .getSingleOrNull();
    return row == null ? null : Map<String, dynamic>.from(jsonDecode(row.read<String>('last_event')) as Map);
  }

  Map<String, dynamic> _downloadRow(QueryRow row) {
    final value = Map<String, dynamic>.from(jsonDecode(row.read<String>('value')) as Map);
    if (value['id'] != row.read<String>('id') ||
        value['scope'] != row.read<String>('scope') ||
        jsonEncode(value['media']) != row.read<String>('media')) {
      throw const TedFailure('invalid_response');
    }
    return value;
  }

  Future<List<Map<String, dynamic>>> allDownloads() async =>
      (await db.customSelect('SELECT * FROM ted_downloads').get()).map(_downloadRow).toList();
  Future<List<Map<String, dynamic>>> downloads(String scope) async =>
      (await db
              .customSelect(
                'SELECT * FROM ted_downloads WHERE scope=? ORDER BY rowid DESC',
                variables: [Variable(scope)],
              )
              .get())
          .map(_downloadRow)
          .toList();
  Future<void> saveDownload(String scope, Map<String, dynamic> value) => _serial(
    () => db.transaction(() async {
      if (value['scope'] != scope) throw const TedFailure('sign_in_required');
      final existing = await db
          .customSelect(
            'SELECT scope,media,value FROM ted_downloads WHERE id=?',
            variables: [Variable(value['id'] as String)],
          )
          .getSingleOrNull();
      if (existing != null &&
          (existing.read<String>('scope') != scope || existing.read<String>('media') != jsonEncode(value['media']))) {
        throw const TedFailure('sign_in_required');
      }
      final retained = Map<String, dynamic>.from(value);
      if (existing != null) {
        final old = jsonDecode(existing.read<String>('value')) as Map;
        // Concurrent transfer/artwork snapshots cannot erase the original
        // download boundary or overwrite a newer account-state cache.
        if (old['status'] == 'complete' && old['downloaded_at'] != null) {
          retained['downloaded_at'] = old['downloaded_at'];
        }
        if (old['download_watch'] != null) retained['download_watch'] = old['download_watch'];
      }
      await db.customStatement(
        'INSERT INTO ted_downloads(id,scope,media,value) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',
        [value['id'], scope, jsonEncode(value['media']), jsonEncode(retained)],
      );
    }),
  );
  Future<void> cacheDownloadWatch(String scope, String id, Map<String, dynamic> watch) => _serial(
    () => db.customStatement(
      r"UPDATE ted_downloads SET value=json_set(value,'$.download_watch',json(?)) WHERE scope=? AND id=?",
      [jsonEncode(watch), scope, id],
    ),
  );
  Future<void> deleteDownload(String scope, String id) =>
      _serial(() => db.customStatement('DELETE FROM ted_downloads WHERE scope=? AND id=?', [scope, id]));

  Future<void> pauseWaitingDownload(String scope, String id) => _serial(
    () => db.customStatement(
      r"UPDATE ted_downloads SET value=json_set(json_remove(value,'$.error'),'$.status','paused') WHERE scope=? AND id=? AND json_extract(value,'$.status')!='complete'",
      [scope, id],
    ),
  );

  Future<List<Map<String, dynamic>>> queuedDownloads(String scope) async =>
      (await db
              .customSelect(
                'SELECT value FROM ted_download_queue WHERE scope=? ORDER BY rowid',
                variables: [Variable(scope)],
              )
              .get())
          .map((row) => Map<String, dynamic>.from(jsonDecode(row.read<String>('value')) as Map))
          .toList();
  Future<void> enqueueDownloads(String scope, List<Map<String, dynamic>> entries) => _serial(
    () => db.transaction(() async {
      for (final entry in entries) {
        if (entry['scope'] != scope) throw const TedFailure('sign_in_required');
        await db.customStatement(
          'INSERT INTO ted_download_queue(id,scope,media,value) VALUES(?,?,?,?) ON CONFLICT(scope,media) DO NOTHING',
          [entry['id'], scope, jsonEncode(entry['media']), jsonEncode(entry)],
        );
      }
    }),
  );
  Future<void> saveQueuedDownload(String scope, Map<String, dynamic> entry) => _serial(() async {
    if (entry['scope'] != scope) throw const TedFailure('sign_in_required');
    await db.customStatement('UPDATE ted_download_queue SET value=? WHERE scope=? AND id=? AND media=?', [
      jsonEncode(entry),
      scope,
      entry['id'],
      jsonEncode(entry['media']),
    ]);
  });

  /// Commit a complete reviewed source plan, fencing entries changed while its
  /// picker was open. Nothing transfers or replaces files before this commit.
  Future<void> saveDownloadPlan(String scope, List<Map<String, dynamic>> entries, bool Function() valid) => _serial(
    () => db.transaction(() async {
      for (final input in entries) {
        if (!valid() || input['scope'] != scope) throw const TedFailure('download_paused');
        final media = jsonEncode(input['media']);
        final files = await db
            .customSelect(
              'SELECT value FROM ted_downloads WHERE scope=? AND media=?',
              variables: [Variable(scope), Variable(media)],
            )
            .get();
        final queue = await db
            .customSelect(
              'SELECT id,value FROM ted_download_queue WHERE scope=? AND media=?',
              variables: [Variable(scope), Variable(media)],
            )
            .getSingleOrNull();
        final expectedQueue = input['expected_queue'];
        final currentFile = files.length == 1 ? jsonDecode(files.single.read<String>('value')) as Map : null;
        final queueStatus = queue == null ? null : (jsonDecode(queue.read<String>('value')) as Map)['status'];
        if (queue?.read<String>('id') != expectedQueue ||
            queue != null &&
                queueStatus != 'failed' &&
                !(queueStatus == 'paused' && currentFile?['status'] == 'failed')) {
          throw const TedFailure('download_changed');
        }
        final replace = input['replace_download'] as Map?;
        if (replace == null && files.isNotEmpty || replace != null && files.length != 1) {
          throw const TedFailure('download_changed');
        }
        if (replace != null) {
          final file = jsonDecode(files.single.read<String>('value')) as Map;
          if (file['id'] != replace['id'] ||
              file['session'] != replace['session'] ||
              file['status'] == 'complete' ||
              file['status'] == 'downloading' ||
              file['status'] != 'failed' && queue == null) {
            throw const TedFailure('download_changed');
          }
        }
        final value = Map<String, dynamic>.from(input)..remove('expected_queue');
        await db.customStatement(
          'INSERT INTO ted_download_queue(id,scope,media,value) VALUES(?,?,?,?) '
          'ON CONFLICT(scope,media) DO UPDATE SET id=excluded.id,value=excluded.value',
          [value['id'], scope, media, jsonEncode(value)],
        );
      }
      if (!valid()) throw const TedFailure('download_paused');
    }),
  );

  Future<void> retryDownloadEntries(String scope, List<Map<String, dynamic>> entries, bool Function() valid) => _serial(
    () => db.transaction(() async {
      for (final entry in entries) {
        if (!valid() || entry['scope'] != scope) throw const TedFailure('download_paused');
        await db.customStatement(
          'INSERT INTO ted_download_queue(id,scope,media,value) VALUES(?,?,?,?) '
          "ON CONFLICT(scope,media) DO UPDATE SET value=excluded.value WHERE json_extract(ted_download_queue.value,'\$.status') IN ('failed','paused')",
          [entry['id'], scope, jsonEncode(entry['media']), jsonEncode(entry)],
        );
      }
      if (!valid()) throw const TedFailure('download_paused');
    }),
  );
  Future<void> deleteQueuedDownload(String scope, String id) =>
      _serial(() => db.customStatement('DELETE FROM ted_download_queue WHERE scope=? AND id=?', [scope, id]));
}
