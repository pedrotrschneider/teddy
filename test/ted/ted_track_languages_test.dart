import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_track_languages.dart';

void main() {
  test('schema 28 upgrade preserves device, downloads, reports and source preferences', () async {
    final directory = await Directory.systemTemp.createTemp('ted-language-upgrade-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/device.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    await db.customStatement("INSERT INTO ted_installation VALUES('device','retained-device')");
    await db.customStatement("INSERT INTO ted_downloads VALUES('copy','owner','movie','{\"retained\":true}')");
    await db.customStatement("INSERT INTO ted_sessions(id,scope,media) VALUES('session','owner','movie')");
    await db.customStatement(
      "INSERT INTO ted_reports(id,session_id,envelope) VALUES('event','session','immutable-report')",
    );
    await db.customStatement("INSERT INTO ted_season_sources VALUES('owner','show',1,'retained-source')");
    await db.customStatement('DROP TABLE ted_track_languages');
    await db.customStatement('DROP TABLE ted_source_cache');
    await db.customStatement('DROP TABLE ted_home_cache');
    await db.customStatement('ALTER TABLE ted_sessions DROP COLUMN qualified');
    await db.customStatement('DROP TABLE ted_profile_pictures');
    await db.customStatement('PRAGMA user_version=28');
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    expect(
      (await db.customSelect('SELECT value FROM ted_installation').getSingle()).read<String>('value'),
      'retained-device',
    );
    expect(
      (await db.customSelect('SELECT value FROM ted_downloads').getSingle()).read<String>('value'),
      '{"retained":true}',
    );
    expect(
      (await db.customSelect('SELECT envelope FROM ted_reports').getSingle()).read<String>('envelope'),
      'immutable-report',
    );
    expect(
      (await db.customSelect('SELECT value FROM ted_season_sources').getSingle()).read<String>('value'),
      'retained-source',
    );
    final store = TedLocalStore(db);
    const episode = TedMediaIdentity('episode', 'tt1234567:1:1');
    await store.rememberTrackLanguage('owner', episode, 'ja', audio: true);
    expect((await store.trackLanguages('owner', episode)).audio, 'ja');
    expect((await db.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), db.schemaVersion);
  });
  test('audio uses language override, origin, English then file default; subtitles stay enabled', () {
    final audio = [
      AudioTrack(id: '1', language: 'eng'),
      AudioTrack(id: '2', language: 'jpn'),
      AudioTrack(id: '3', language: 'por', isDefault: true),
    ];
    final subtitles = [
      SubtitleTrack(id: '4', language: 'eng', isForced: true),
      SubtitleTrack(id: '5', language: 'en-US'),
      SubtitleTrack(id: '6', language: 'por', isDefault: true),
    ];
    expect(const TedTrackLanguages().audioTrack(audio, 'ja').id, '2');
    expect(const TedTrackLanguages(audio: 'pt-BR').audioTrack(audio, 'ja').id, '3');
    expect(const TedTrackLanguages(audio: 'deu').audioTrack(audio, 'ja').id, '2');
    expect(const TedTrackLanguages().audioTrack(audio, 'fra').id, '1');
    expect(const TedTrackLanguages().audioTrack(audio.skip(1).toList(), 'fra').id, '3');
    expect(const TedTrackLanguages().subtitleTrack(subtitles).id, '5');
    expect(const TedTrackLanguages(subtitle: 'pt').subtitleTrack(subtitles).id, '6');
    expect(const TedTrackLanguages(subtitle: 'de').subtitleTrack(subtitles.skip(2).toList()).id, '6');
    expect(const TedTrackLanguages().subtitleTrack([]), SubtitleTrack.auto);
  });
  test('initial container choices preserve policy and manual choices without guessing incomplete inventories', () {
    final technical = <String, dynamic>{
      'format': {'format_name': 'matroska,webm'},
      'streams': [
        {'index': 0, 'codec_type': 'video'},
        {
          'index': 1,
          'codec_type': 'audio',
          'tags': {'language': 'jpn'},
          'disposition': {'default': 1},
        },
        {
          'index': 2,
          'codec_type': 'audio',
          'tags': {'language': 'eng'},
        },
        {
          'index': 3,
          'codec_type': 'subtitle',
          'tags': {'language': 'eng'},
          'disposition': {'default': 1, 'forced': 1},
        },
        {
          'index': 4,
          'codec_type': 'subtitle',
          'tags': {'language': 'eng'},
        },
        {'index': 5, 'codec_type': 'attachment'},
        {'index': 6, 'codec_type': 'video'},
      ],
    };
    final container = TedContainerTracks.fromTechnical(technical)!;
    final initial = const TedTrackLanguages().initialTracks(container, 'ja');
    expect(initial.audio?.id, '1');
    expect(initial.subtitle?.id, '2'); // English dialogue, ahead of forced signs.
    expect(const TedTrackLanguages(audio: 'en').initialTracks(container, 'ja').audio?.id, '2');
    final manual = const TedTrackLanguages().initialTracks(
      container,
      'ja',
      audioId: '2',
      subtitleId: 'no',
      secondarySubtitleId: '1',
    );
    expect(manual.audio?.id, '2');
    expect(manual.subtitle, SubtitleTrack.off);
    expect(manual.secondarySubtitle?.id, '1');
    final external = const TedTrackLanguages().initialTracks(container, 'ja', externalSubtitles: true);
    expect(external.audio?.id, '1');
    expect(external.subtitle, isNull); // A sidecar can contain several native tracks.
    final missing = const TedTrackLanguages().initialTracks(container, 'ja', audioId: '99', subtitleId: '99');
    expect(missing.audio?.id, initial.audio?.id);
    expect(missing.subtitle?.id, initial.subtitle?.id);
    for (final broken in [
      null,
      {
        'format': {'format_name': 'mpegts'},
        'streams': technical['streams'],
      },
      {...technical, 'streams': (technical['streams'] as List).skip(1).toList()},
      {
        ...technical,
        'streams': [
          {'index': 0, 'codec_type': 'audio', 'tags': false},
        ],
      },
      {
        ...technical,
        'streams': [
          {
            'index': 0,
            'codec_type': 'audio',
            'disposition': {'default': 'yes'},
          },
        ],
      },
    ]) {
      expect(TedContainerTracks.fromTechnical(broken), isNull);
    }
  });
  test('local language writes merge, survive reopening, share episodes of a show and isolate accounts', () async {
    final directory = await Directory.systemTemp.createTemp('ted-language-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/local.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final store = TedLocalStore(db);
    const episode = TedMediaIdentity('episode', 'tt1234567:1:2');
    await Future.wait([
      store.rememberTrackLanguage('owner', episode, 'jpn', audio: true),
      store.rememberTrackLanguage('owner', episode, 'por', audio: false),
    ]);
    await store.close();
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    final reloaded = TedLocalStore(reopened);
    final prefs = await reloaded.trackLanguages('owner', const TedMediaIdentity('episode', 'tt1234567:3:8'));
    expect(prefs.audio, 'ja');
    expect(prefs.subtitle, 'pt');
    expect((await reloaded.trackLanguages('other', episode)).audio, '');
    expect((await reloaded.trackLanguages('owner', const TedMediaIdentity('movie', 'tt1234567'))).audio, '');
    await reloaded.close();
    await reopened.close();
  });
}
