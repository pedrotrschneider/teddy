import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_local_store.dart';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/focus/transport_keys.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_playback.dart';
import 'package:plezy/ted/ted_playback_chapters.dart';
import 'package:plezy/utils/log_redaction_manager.dart';
import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/subtitle_fonts.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response, signInRequired;

const sessionId = '33333333-3333-4333-8333-333333333333';
const mediaPath = '/api/client/v1/playback/sessions/$sessionId/media';

class ControlFixture {
  final int pinnedDuration;
  final int resumeMs;
  final int expectedDuration;
  ControlFixture({this.pinnedDuration = 100000, this.resumeMs = 10000, this.expectedDuration = 0});
  DateTime now = DateTime.utc(2026, 10, 10);
  int rotations = 0;
  final refreshEntered = Completer<void>();
  Completer<void>? releaseRefresh;
  bool rejectAudio = false;
  bool rejectPause = false;
  bool rejectReports = false;
  Completer<void>? releaseReports;
  Completer<void>? releaseDispose;
  bool? nativeEof;
  bool nativeSeeking = false;
  final calls = <MethodCall>[];
  final reports = <Map<String, dynamic>>[];
  late final auth = TedAuth(
    store: MemoryStore(),
    now: () => now,
    client: MockClient((request) async {
      if (request.url.path.endsWith('/login')) return response(pair(now));
      if (request.url.path.endsWith('/refresh')) {
        rotations++;
        if (!refreshEntered.isCompleted) refreshEntered.complete();
        if (releaseRefresh != null) await releaseRefresh!.future;
        return response(pair(now, suffix: String.fromCharCode(97 + rotations)));
      }
      final events = (jsonDecode(request.body)['events'] as List).cast<Map<String, dynamic>>();
      reports.addAll(events);
      await releaseReports?.future;
      if (rejectReports) return response({'error': 'unavailable'}, 503);
      return response({
        'events': [
          for (final event in events) {'id': event['id'], 'outcome': 'applied', 'duplicate': false},
        ],
      });
    }),
  );
  late final player = PlayerNative();
  late final playback = TedPlayback(
    TedClient(auth),
    player,
    TedPlaybackSession(
      sessionId,
      const TedMediaIdentity('movie', 'tt1234567'),
      mediaPath,
      pinnedDuration,
      resumeMs,
      expectedDurationMs: expectedDuration,
    ),
  );
  Future<Object?> method(MethodCall call) async {
    calls.add(call);
    if (call.method == 'dispose') await releaseDispose?.future;
    if (call.method == 'getProperty') {
      return switch ((call.arguments as Map)['name']) {
        'eof-reached' => (nativeEof ?? player.state.completed) ? 'yes' : 'no',
        'seeking' => nativeSeeking ? 'yes' : 'no',
        'time-pos' => (player.decodedPosition.inMilliseconds / 1000).toString(),
        'duration' => (player.state.duration.inMilliseconds / 1000).toString(),
        _ => null,
      };
    }
    if (call.method == 'setProperty' && (call.arguments as Map)['name'] == 'aid' && rejectAudio) {
      throw PlatformException(code: 'SET_PROPERTY_FAILED', message: 'private native diagnostic');
    }
    if (call.method == 'setProperty' && (call.arguments as Map)['name'] == 'pause' && rejectPause) {
      throw PlatformException(code: 'SET_PROPERTY_FAILED', message: 'Decoder already stopped');
    }
    return call.method == 'initialize' ? true : null;
  }

  Future<void> open() async {
    await auth.login('https://ted.example', 'fixture', '', 'Track control fixture');
    await playback.open();
    await loaded();
    player.handlePropertyChange('pause', false);
    player.handlePropertyChange('time-pos', 17.0);
    await Future<void>.value();
  }

  Future<void> loaded() async {
    player.handlePlayerEvent('start-file', null);
    player.handlePlayerEvent('file-loaded', null);
    player.handlePropertyChange('time-pos', 17.0);
    player.handlePropertyChange('track-list', [
      {'type': 'audio', 'id': 1, 'lang': 'eng', 'selected': true},
      {'type': 'audio', 'id': 2, 'lang': 'por'},
      {'type': 'sub', 'id': 3, 'lang': 'eng'},
    ]);
    final start = calls.lastWhere((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'start');
    final position = double.tryParse((start.arguments as Map)['value'] as String) ?? 0;
    player.handlePlayerEvent('playback-restart', {'positionSeconds': position});
    await Future<void>.value();
    await Future<void>.value();
  }

  Future<void> close() async {
    await playback.closePlayer();
    auth.close();
  }

  Future<void> closeWithFrames(WidgetTester tester) async {
    var finished = false;
    final closing = close().whenComplete(() => finished = true);
    // Native channel cancellation and fake-clock stream closures both need
    // their owning event loop driven; waiting in only one zone deadlocks it.
    for (var i = 0; i < 20 && !finished; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(finished, true);
    await closing;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(prepareSubtitleFonts);
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
  });

  for (final offline in [false, true]) {
    test('backward seek checkpoints confirmed viewing before native entry (offline=$offline)', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final journal = TedLocalStore(db);
      final f = ControlFixture(resumeMs: 0)
        ..rejectReports = true
        ..releaseReports = Completer<void>();
      await f.auth.login('https://ted.example', 'fixture', '', 'Seek checkpoint');
      final playback = TedPlayback(
        TedClient(f.auth),
        f.player,
        TedPlaybackSession(sessionId, const TedMediaIdentity('movie', 'tt1234567'), mediaPath, 100000, 0),
        journal: journal,
        offline: offline,
      );
      final scope = tedOfflineScope(f.auth)!;
      Map<String, dynamic>? beforeSeek;
      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        methodHandler: (call) async {
          if (call.method == 'command' && (call.arguments as Map)['args'][0] == 'seek') {
            beforeSeek = await journal.lastPosition(scope, playback.session.media);
            expect(f.releaseReports!.isCompleted, false, reason: 'local checkpoint must not await a server receipt');
            // A decoder failure may reset time-pos without rendering the target.
            f.player.handlePropertyChange('time-pos', 0.0);
            if (offline) throw PlatformException(code: 'SEEK_FAILED');
          }
          return f.method(call);
        },
        testBody: () async {
          try {
            await playback.open();
            await f.loaded();
            f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
            await Future<void>.delayed(Duration.zero);
            await playback.seek(const Duration(seconds: 2));
            expect(beforeSeek?['kind'], 'progress');
            expect(beforeSeek?['position_ms'], 17000);
            expect(beforeSeek?['natural_eof'], false);
            // Leaving before the new frame must not replace qualified viewing
            // with an optimistic two-second target or the decoder's reset zero.
            await playback.stop();
            final saved = await journal.lastPosition(scope, playback.session.media);
            expect(saved?['kind'], 'stop');
            expect(saved?['position_ms'], 17000);
            expect(saved?['natural_eof'], false);
          } finally {
            f.releaseReports!.complete();
            await playback.closePlayer();
          }
        },
      );
      await journal.close();
      f.auth.close();
    });
  }

  test('a decoded backward landing is saved immediately and keeps qualified viewing below five percent', () async {
    final root = await Directory.systemTemp.createTemp('ted-seek-checkpoint-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/device.sqlite');
    var journal = TedLocalStore(AppDatabase.forTesting(NativeDatabase(file)));
    final f = ControlFixture(resumeMs: 0)..rejectReports = true;
    await f.auth.login('https://ted.example', 'fixture', '', 'Landed seek checkpoint');
    final playback = TedPlayback(
      TedClient(f.auth),
      f.player,
      const TedPlaybackSession(sessionId, TedMediaIdentity('movie', 'tt1234567'), mediaPath, 100000, 0),
      journal: journal,
    );
    final scope = tedOfflineScope(f.auth)!;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await playback.open();
          await f.loaded();
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
          await Future<void>.delayed(Duration.zero);
          await playback.seek(const Duration(seconds: 2));
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 2.1});
          await Future<void>.delayed(Duration.zero);
          await playback.flush();
          final landed = await journal.lastPosition(scope, playback.session.media);
          expect(landed?['kind'], 'progress');
          expect(landed?['position_ms'], 2100);
          expect(landed?['natural_eof'], false);
        } finally {
          await playback.closePlayer();
        }
      },
    );
    await journal.close();
    journal = TedLocalStore(AppDatabase.forTesting(NativeDatabase(file)));
    await journal.recoverInterrupted();
    final restored = await journal.lastPosition(scope, playback.session.media);
    expect(restored?['position_ms'], 2100);
    expect(restored?['kind'], 'stop');
    expect(restored?['natural_eof'], false);
    await journal.close();
    f.auth.close();
  });

  test('forced close saves a stop first and concurrent callers join native disposal', () async {
    final f = ControlFixture()..releaseDispose = Completer<void>();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          final first = f.playback.closePlayer();
          var joined = false;
          final second = f.playback.closePlayer().then((_) => joined = true);
          while (!f.calls.any((call) => call.method == 'dispose')) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(f.reports.last['kind'], 'stop');
          expect(f.reports.last['position_ms'], 17000);
          expect(joined, false);
          f.releaseDispose!.complete();
          await Future.wait([first, second]);
          expect(f.calls.where((call) => call.method == 'dispose'), hasLength(1));
          expect(f.reports.where((report) => report['kind'] == 'stop'), hasLength(1));
        } finally {
          if (!f.releaseDispose!.isCompleted) f.releaseDispose!.complete();
          await f.close();
        }
      },
    );
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    for (final hardware in [true, false]) {
      test(
        '$platform startup respects decoding=$hardware and keeps read-ahead independent of initial buffering',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          final settings = await SettingsService.getInstance();
          await settings.write(SettingsService.enableHardwareDecoding, hardware);
          final f = ControlFixture();
          try {
            await withMockPlayerChannels(
              methodChannelName: 'com.plezy/mpv_player',
              eventChannelName: 'com.plezy/mpv_player/events',
              methodHandler: f.method,
              testBody: () async {
                await f.open();
                final properties = {
                  for (final call in f.calls.where((c) => c.method == 'setProperty'))
                    (call.arguments as Map)['name']: (call.arguments as Map)['value'],
                };
                expect(
                  properties['hwdec'],
                  hardware ? (platform == TargetPlatform.android ? 'mediacodec' : 'videotoolbox') : 'no',
                );
                final decoderWrite = f.calls.indexWhere(
                  (c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'hwdec',
                );
                final open = f.calls.indexWhere(
                  (c) => c.method == 'command' && ((c.arguments as Map)['args'] as List).first == 'loadfile',
                );
                expect(open, greaterThanOrEqualTo(0));
                expect(decoderWrite, lessThan(open), reason: 'Select the decoder before opening the source');
                expect(properties['cache-pause-initial'], 'no');
                expect(properties['cache-pause-wait'], '0.5');
                expect(properties.containsKey('demuxer-max-bytes'), false);
                expect(properties.containsKey('cache-secs'), false);
                await f.close();
              },
            );
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );
    }
  }

  test('short status video and its EOF never generate watch reports or completion', () async {
    final f = ControlFixture(pinnedDuration: 0, resumeMs: 0, expectedDuration: 1200000);
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          expect(f.reports, isEmpty); // wait for the actual file duration
          f.player.handlePropertyChange('duration', 8.0);
          f.player.handlePropertyChange('time-pos', 8.0);
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          await f.playback.stop(naturalEof: true);
          expect(f.reports, isEmpty);
          expect(f.playback.completedNaturally, false);
          expect(f.playback.failure?.code, 'source_placeholder');
        } finally {
          await f.close();
        }
      },
    );
  });
  test('real duration above 30 percent releases the delayed start exactly once', () async {
    final f = ControlFixture(pinnedDuration: 0, resumeMs: 0, expectedDuration: 100000);
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          expect(f.reports, isEmpty);
          f.player.handlePropertyChange('duration', 30.001);
          await Future<void>.delayed(Duration.zero);
          await f.playback.flush();
          expect(f.reports.where((e) => e['kind'] == 'start').length, 1);
          expect(f.playback.failure, isNull);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('decoding and resume settings reach the native player and the durable start position', () async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.enableHardwareDecoding, false);
    await settings.write(SettingsService.rewindOnResume, 3);
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          expect(
            f.calls.where(
              (c) =>
                  c.method == 'setProperty' &&
                  (c.arguments as Map)['name'] == 'hwdec' &&
                  (c.arguments as Map)['value'] == 'no',
            ),
            isNotEmpty,
          );
          final start = f.calls.firstWhere((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'start');
          expect((start.arguments as Map)['value'], '7.0');
          await f.playback.stop();
          expect(f.reports.first['position_ms'], 7000);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('embedded chapters use Plezy patterns and pinned duration without a metadata server', () async {
    await SettingsService.getInstance();
    final f = ControlFixture();
    var count = '3';
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'getProperty') {
          final property = (call.arguments as Map)['name'];
          if (property == 'chapter-list/count') return count;
          const values = {
            'chapter-list/0/time': '0',
            'chapter-list/0/title': 'OP1',
            'chapter-list/1/time': '90',
            'chapter-list/1/title': 'Story',
            'chapter-list/2/time': '150',
            'chapter-list/2/title': 'ED',
          };
          if (values.containsKey(property)) return values[property];
        }
        return f.method(call);
      },
      testBody: () async {
        try {
          final extras = await tedPlaybackChapters(f.player, durationMs: 180000);
          expect(extras.chapters.length, 3);
          expect(extras.markers.map((m) => m.type), ['intro', 'credits']);
          expect(extras.markers.last.endTimeOffset, 180000);
          count = '2001';
          expect((await tedPlaybackChapters(f.player)).chapters, isEmpty);
        } finally {
          await f.player.dispose();
          f.auth.close();
        }
      },
    );
  });

  test('offline file controls work after access expiry and stop is durable without a server receipt', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final journal = TedLocalStore(db);
    final f = ControlFixture();
    var now = DateTime.utc(2026, 10, 10);
    var network = 0;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        network++;
        throw const SocketException('offline');
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'offline');
    now = now.add(const Duration(minutes: 11));
    final playback = TedPlayback(
      TedClient(auth),
      f.player,
      const TedPlaybackSession(sessionId, TedMediaIdentity('movie', 'tt1234567'), '/device/movie.bin', 100000, 7000),
      journal: journal,
      offline: true,
    );
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await playback.open();
          await f.loaded();
          await playback.seek(const Duration(seconds: 20));
          await playback.selectAudioTrack(f.player.state.tracks.audio.last);
          f.player.handlePropertyChange('time-pos', 21.0);
          f.player.handlePlayerEvent('playback-restart', null);
          await Future<void>.delayed(Duration.zero);
          await playback.stop();
          expect(await journal.pending(tedOfflineScope(auth)!), 4);
          final saved = await journal.lastPosition(tedOfflineScope(auth)!, playback.session.media);
          expect(saved!['kind'], 'stop');
          expect(saved['position_ms'], 21000);
          expect(saved['natural_eof'], false);
          expect(saved['origin'], 'offline');
          final loads = f.calls
              .where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile')
              .toList();
          expect(loads.length, 1);
          expect((loads.single.arguments as Map)['args'][1], '/device/movie.bin');
          expect(network, lessThanOrEqualTo(1));
        } finally {
          await playback.closePlayer();
        }
      },
    );
  });

  test('original language and locally saved language overrides drive native tracks online and offline', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final journal = TedLocalStore(db);
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        await f.auth.login('https://ted.example', 'fixture', '', 'Language fixture');
        const media = TedMediaIdentity('episode', 'tt1234567:1:2');
        for (final offline in [false, true]) {
          final player = PlayerNative();
          final playback = TedPlayback(
            TedClient(f.auth),
            player,
            TedPlaybackSession(
              sessionId,
              media,
              offline ? '/device/episode.bin' : mediaPath,
              100000,
              0,
              originalLanguage: 'jpn',
            ),
            journal: journal,
            offline: offline,
          );
          try {
            await playback.open();
            player.handlePlayerEvent('start-file', null);
            player.handlePlayerEvent('file-loaded', null);
            player.handlePropertyChange('track-list', [
              {'type': 'audio', 'id': 1, 'lang': 'eng', 'default': true},
              {'type': 'audio', 'id': 2, 'lang': 'jpn'},
              {'type': 'sub', 'id': 3, 'lang': 'eng'},
              {'type': 'sub', 'id': 4, 'lang': 'por'},
            ]);
            await Future<void>.delayed(Duration.zero);
            while (playback.controlsBusy) {
              await Future<void>.delayed(Duration.zero);
            }
            final audio = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'aid');
            final subtitles = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'sid');
            expect((audio.last.arguments as Map)['value'], offline ? '1' : '2');
            expect((subtitles.last.arguments as Map)['value'], offline ? '4' : '3');
            if (!offline) {
              await playback.selectAudioTrack(player.state.tracks.audio.first);
              await playback.selectSubtitleTrack(player.state.tracks.subtitle.last);
            }
            await playback.stop();
          } finally {
            await playback.closePlayer();
          }
        }
      },
    );
    await journal.close();
    await db.close();
    f.auth.close();
  });

  test('unbuffered seeks ignore optimistic and transient EOF until decoded playback resumes', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          for (final seconds in [95, 40]) {
            await f.playback.seek(Duration(seconds: seconds));
            f.player.handlePropertyChange('eof-reached', true);
            await Future<void>.delayed(Duration.zero);
            expect(f.playback.completedNaturally, false);
            expect(
              f.calls.where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile').length,
              1,
            );
            f.player.handlePropertyChange('time-pos', seconds.toDouble());
            f.player.handlePropertyChange('eof-reached', false);
            f.player.handlePlayerEvent('playback-restart', null);
            await Future<void>.delayed(Duration.zero);
          }
          f.player.handlePropertyChange('time-pos', 100.0);
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          await f.playback.stop();
          expect(f.playback.completedNaturally, true);
          expect(f.reports.last['natural_eof'], true);
        } finally {
          await f.close();
        }
      },
    );
  });

  testWidgets('resume jumping to EOF before its requested frame recovers without completion or lost position', (
    tester,
  ) async {
    final f = ControlFixture(pinnedDuration: 0, resumeMs: 403111);
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.auth.login('https://ted.example', 'fixture', '', 'Resume fixture');
          await f.playback.open();
          f.player.handlePlayerEvent('start-file', {'sourceId': 51});
          f.player.handlePlayerEvent('file-loaded', {'sourceId': 51});
          f.player.handlePropertyChange('duration', 1365.501);
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 51, 'positionSeconds': 1365.501});
          f.player.handlePropertyChange('eof-reached', true);
          await tester.pump();
          expect(f.playback.completedNaturally, false);
          expect(f.playback.timelinePosition.value, const Duration(milliseconds: 403111));
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          final starts = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'start');
          expect(starts.length, 2);
          expect((starts.last.arguments as Map)['value'], '403.111');
          await f.loaded();
          await tester.pump();
          await f.playback.stop();
          expect(f.reports.last['position_ms'], 403111);
          expect(f.reports.every((r) => r['natural_eof'] == false), true);
          expect(f.reports.map((r) => r['kind']), ['start', 'stop']);
        } finally {
          await f.closeWithFrames(tester);
        }
      },
    );
  });

  testWidgets('a silent seek stall retries the pinned target three times and then exposes an interruption', (
    tester,
  ) async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          await f.playback.transport(TransportCommand.pause);
          await f.playback.seek(const Duration(seconds: 40));
          for (var attempt = 0; attempt < 4; attempt++) {
            await tester.pump(const Duration(seconds: 15));
            await tester.pump();
            expect(f.playback.completedNaturally, false);
          }
          final loads = f.calls.where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile');
          expect(loads.length, 4);
          expect(loads.every((c) => (c.arguments as Map)['args'][1] == 'https://ted.example$mediaPath'), true);
          final starts = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'start');
          expect(starts.skip(1).every((c) => (c.arguments as Map)['value'] == '40.0'), true);
          expect(f.playback.wantsToPlay, false);
          expect(f.playback.failure?.code, 'playback_interrupted');
          await f.playback.stop();
          expect(f.reports.last['position_ms'], 17000);
          expect(f.reports.every((r) => r['natural_eof'] == false), true);
        } finally {
          await f.closeWithFrames(tester);
        }
      },
    );
  });

  testWidgets('a resumed seek cancels its watchdog and queued EOF must agree with live native state', (tester) async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          await f.playback.seek(const Duration(seconds: 40));
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 40.0});
          await tester.pump();
          await tester.pump(const Duration(seconds: 16));
          expect(
            f.calls.where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile').length,
            1,
          );
          f.nativeEof = false;
          f.player.handlePropertyChange('time-pos', 100.0);
          f.player.handlePropertyChange('eof-reached', true);
          await tester.pump();
          expect(f.playback.completedNaturally, false);
          f.nativeEof = true;
          f.nativeSeeking = true;
          f.player.handlePropertyChange('eof-reached', true);
          await tester.pump();
          expect(f.playback.completedNaturally, false);
          f.nativeSeeking = false;
          f.player.handlePropertyChange('eof-reached', true);
          await tester.pump();
          await f.playback.stop();
          expect(f.playback.completedNaturally, true);
          expect(f.reports.last['position_ms'], 100000);
          expect(f.reports.last['natural_eof'], true);
        } finally {
          await f.closeWithFrames(tester);
        }
      },
    );
  });

  testWidgets('stalled active playback recovers at its observed position while paused playback remains untouched', (
    tester,
  ) async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
          await tester.pump();
          await tester.pump(const Duration(seconds: 15));
          await tester.pump(const Duration(seconds: 15));
          final loads = f.calls.where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile');
          expect(loads.length, 2);
          final start = f.calls.lastWhere((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'start');
          expect((start.arguments as Map)['value'], '17.0');
          await f.loaded();
          await f.playback.transport(TransportCommand.pause);
          await tester.pump(const Duration(seconds: 60));
          expect(loads.length, 2);
          expect(f.playback.failure, isNull);
          expect(f.playback.completedNaturally, false);
          await f.playback.stop();
          expect(f.reports.last['position_ms'], 17000);
          expect(f.reports.every((r) => r['natural_eof'] == false), true);
        } finally {
          await f.closeWithFrames(tester);
        }
      },
    );
  });

  test('a held EOF read cannot complete a newer seek or suppress its subsequent genuine end', () async {
    final f = ControlFixture();
    final entered = Completer<void>();
    final release = Completer<void>();
    var held = false;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'getProperty' && (call.arguments as Map)['name'] == 'eof-reached' && !held) {
          held = true;
          entered.complete();
          await release.future;
        }
        return f.method(call);
      },
      testBody: () async {
        try {
          await f.open();
          f.player.handlePropertyChange('time-pos', 100.0);
          f.player.handlePropertyChange('eof-reached', true);
          await entered.future;
          await f.playback.seek(const Duration(seconds: 40));
          f.player.handlePropertyChange('eof-reached', false);
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 40.0});
          await Future<void>.delayed(Duration.zero);
          expect(f.playback.completedNaturally, false);
          f.player.handlePropertyChange('time-pos', 100.0);
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          expect(f.playback.completedNaturally, true);
          release.complete();
          await f.playback.stop();
          expect(f.reports.where((r) => r['kind'] == 'stop').length, 1);
          expect(f.reports.last['natural_eof'], true);
        } finally {
          if (!release.isCompleted) release.complete();
          await f.close();
        }
      },
    );
  });

  test('truncated EOF beyond watched threshold is not natural completion', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.player.handlePropertyChange('time-pos', 93.0);
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          while (f.playback.controlsBusy) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(f.playback.completedNaturally, false);
          expect(f.reports.every((e) => e['natural_eof'] == false), true);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('unknown duration and no decoded playback cannot turn a load/seek EOF into completion', () async {
    final f = ControlFixture(pinnedDuration: 0);
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.auth.login('https://ted.example', 'fixture', '', 'Unknown duration');
          await f.playback.open();
          f.player.handlePlayerEvent('start-file', null);
          f.player.handlePlayerEvent('file-loaded', null);
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          expect(f.playback.completedNaturally, false);
          f.player.handlePropertyChange('eof-reached', false);
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 10.0});
          await Future<void>.delayed(Duration.zero);
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
          await Future<void>.delayed(Duration.zero);
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          await f.playback.stop();
          expect(f.reports.last['natural_eof'], true);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('later restart snapshots replace optimistic positions; stale restart cannot finish a backward seek', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('start-file', {'sourceId': 73});
          f.player.handlePlayerEvent('file-loaded', {'sourceId': 73});
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 73, 'positionSeconds': 99.0});
          await Future<void>.delayed(Duration.zero);
          expect(f.playback.timelinePosition.value, const Duration(seconds: 99));
          await f.playback.seek(const Duration(seconds: 40));
          expect(f.player.currentPosition, const Duration(seconds: 40));
          expect(f.player.decodedPosition, const Duration(seconds: 99));
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 73, 'positionSeconds': 99.0});
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          expect(f.playback.completedNaturally, false);
          expect(f.playback.timelinePosition.value, const Duration(seconds: 40));
          f.player.handlePropertyChange('eof-reached', false);
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 73, 'positionSeconds': 39.9});
          await Future<void>.delayed(Duration.zero);
          expect(f.player.decodedPosition, const Duration(milliseconds: 39900));
          expect(f.playback.timelinePosition.value, const Duration(milliseconds: 39900));
          await f.playback.seek(const Duration(seconds: 95));
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          expect(f.playback.completedNaturally, false);
          f.player.handlePropertyChange('eof-reached', false);
          f.player.handlePlayerEvent('playback-restart', {'sourceId': 73, 'positionSeconds': 94.9});
          await Future<void>.delayed(Duration.zero);
          expect(f.playback.timelinePosition.value, const Duration(milliseconds: 94900));
          f.player.handlePropertyChange('time-pos', 100.0, sourceId: 73);
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          await f.playback.stop();
          expect(f.playback.completedNaturally, true);
          expect(f.reports.last['natural_eof'], true);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('a failed seek range reopens only the pinned session at its target, with bounded recovery', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          for (final target in [40, 20, 10, 5]) {
            await f.playback.seek(Duration(seconds: target));
            f.player.handlePlayerEvent('end-file', {'reason': 'error', 'message': 'HTTP error 503'});
            await Future<void>.delayed(Duration.zero);
            while (f.playback.controlsBusy) {
              await Future<void>.delayed(Duration.zero);
            }
            expect(f.playback.completedNaturally, false);
            if (target != 5) {
              final starts = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'start');
              expect((starts.last.arguments as Map)['value'], '$target.0');
              await f.loaded();
            }
          }
          final loads = f.calls.where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile');
          expect(loads.length, 4);
          expect(loads.every((c) => (c.arguments as Map)['args'][1] == 'https://ted.example$mediaPath'), true);
          expect(f.playback.failure?.code, 'playback_failed');
          expect(f.reports.every((r) => r['natural_eof'] == false), true);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('premature EOF reopens the same session at its observed offset without completion', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          await f.playback.reconnect();
          await f.loaded();
          await f.playback.flush();
          expect(f.playback.completedNaturally, false);
          expect(f.reports.map((e) => e['kind']), ['start', 'progress']);
          expect(f.reports.every((e) => e['natural_eof'] == false), true);
          final starts = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'start');
          expect((starts.last.arguments as Map)['value'], '17.0');
          await f.playback.stop();
          expect(f.reports.last['position_ms'], 17000);
          expect(f.reports.last['natural_eof'], false);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('repeated early ends stay on the player with saved progress and bounded retries', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          for (var i = 0; i < 4; i++) {
            f.player.handlePropertyChange('eof-reached', true);
            await Future<void>.delayed(Duration.zero);
            while (f.playback.controlsBusy) {
              await Future<void>.delayed(Duration.zero);
            }
            if (i < 3) {
              await f.loaded();
              f.player.handlePlayerEvent('playback-restart', null);
            }
          }
          await f.playback.flush();
          expect(f.rotations, 0);
          expect(f.playback.completedNaturally, false);
          expect(f.playback.failure?.code, 'playback_interrupted');
          expect(f.reports.every((e) => e['natural_eof'] == false), true);
          await f.playback.stop();
          expect(f.reports.last['kind'], 'stop');
          expect(f.reports.last['position_ms'], 17000);
        } finally {
          await f.close();
        }
      },
    );
  });

  test(
    'learned add-on duration survives reload so another early EOF cannot become unknown-length completion',
    () async {
      final f = ControlFixture(pinnedDuration: 0);
      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        methodHandler: f.method,
        testBody: () async {
          try {
            await f.open();
            f.player.handlePropertyChange('duration', 100.0);
            await Future<void>.delayed(Duration.zero);
            expect(f.playback.durationMs, 100000);
            for (var attempt = 0; attempt < 2; attempt++) {
              f.player.handlePropertyChange('eof-reached', true);
              await Future<void>.delayed(Duration.zero);
              while (f.playback.controlsBusy) {
                await Future<void>.delayed(Duration.zero);
              }
              await f.loaded();
              f.player.handlePlayerEvent('playback-restart', null);
              expect(f.player.state.duration, Duration.zero);
              expect(f.playback.durationMs, 100000);
            }
            await f.playback.flush();
            expect(f.rotations, 0);
            expect(f.playback.completedNaturally, false);
            expect(f.reports.every((e) => e['kind'] != 'stop' && e['natural_eof'] == false), true);
          } finally {
            await f.close();
          }
        },
      );
    },
  );
  test(
    'track changes retain the buffer after token expiry and preserve selected tracks on an actual reconnect',
    () async {
      final f = ControlFixture();
      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        methodHandler: f.method,
        testBody: () async {
          try {
            await f.open();
            f.now = f.now.add(const Duration(minutes: 11));
            await f.playback.selectAudioTrack(f.player.state.tracks.audio.last);
            expect(f.rotations, 0);
            final loads = f.calls
                .where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile')
                .toList();
            expect(loads.length, 1);
            expect((loads.last.arguments as Map)['args'][1], 'https://ted.example$mediaPath');
            final starts = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'start');
            expect((starts.last.arguments as Map)['value'], '10.0');
            await f.loaded();
            final audio = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'aid');
            expect((audio.last.arguments as Map)['value'], '2');
            await f.playback.selectSubtitleTrack(f.player.state.tracks.subtitle.single);
            await f.playback.reconnect();
            await f.loaded();
            final subtitle = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'sid');
            expect((subtitle.last.arguments as Map)['value'], '3');
            expect(f.playback.failure, isNull);
          } finally {
            await f.close();
          }
        },
      );
    },
  );
  for (final pausedByUser in [false, true]) {
    test('HTTP recovery preserves ${pausedByUser ? 'paused' : 'playing'} intent after the backend stops', () async {
      final f = ControlFixture();
      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        methodHandler: f.method,
        testBody: () async {
          try {
            await f.open();
            if (pausedByUser) await f.playback.playOrPause();
            f.player.handlePropertyChange(
              'pause',
              true,
            ); // The failed decoder/HTTP read stopped, independent of user intent.
            f.releaseRefresh = Completer<void>();
            f.player.debugSimulateServerHttpError(401);
            await f.refreshEntered.future;
            final recovery = f.playback.reconnect();
            f.releaseRefresh!.complete();
            await recovery;
            final pauses = f.calls.where((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'pause');
            expect((pauses.last.arguments as Map)['value'], pausedByUser ? 'yes' : 'no');
            expect(f.playback.wantsToPlay, !pausedByUser);
            expect(f.rotations, 1);
          } finally {
            await f.close();
          }
        },
      );
    });
  }
  test('a rejected track command remains contained and a valid retry clears its safe failure', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.rejectAudio = true;
          await f.playback.selectAudioTrack(f.player.state.tracks.audio.last);
          expect(f.playback.failure?.code, 'track_unavailable');
          expect(f.playback.failure?.message, isNot(contains('private native diagnostic')));
          expect(f.auth.signedIn, isTrue);
          f.rejectAudio = false;
          await f.playback.selectAudioTrack(f.player.state.tracks.audio.last);
          expect(f.playback.failure, isNull);
          expect(f.playback.controlsBusy, isFalse);
        } finally {
          await f.close();
        }
      },
    );
  });
  test('stop during a held credential refresh fences the reopen and records one final position', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.now = f.now.add(const Duration(minutes: 11));
          f.releaseRefresh = Completer<void>();
          final selection = f.playback.reconnect();
          await f.refreshEntered.future;
          final stop = f.playback.stop();
          expect(f.reports.where((event) => event['kind'] == 'stop'), isEmpty);
          f.releaseRefresh!.complete();
          await Future.wait([selection, stop]);
          await f.playback.stop();
          final stops = f.reports.where((event) => event['kind'] == 'stop');
          expect(stops.length, 1);
          expect(stops.single['position_ms'], 17000);
          final loads = f.calls.where((c) => c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile');
          expect(loads.length, 1);
        } finally {
          await f.close();
        }
      },
    );
  });
  test('a later track-list observation cannot hide a failed playback source', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          for (var attempt = 0; attempt < 4; attempt++) {
            f.player.debugSimulateServerHttpError(503);
            await Future<void>.delayed(Duration.zero);
            while (f.playback.controlsBusy) {
              await Future<void>.delayed(Duration.zero);
            }
            if (attempt < 3) await f.loaded();
          }
          f.player.handlePropertyChange('track-list', [
            {'type': 'audio', 'id': 1, 'lang': 'eng', 'selected': true},
          ]);
          await Future<void>.delayed(Duration.zero);
          expect(f.playback.failure?.code, 'playback_failed');
        } finally {
          await f.close();
        }
      },
    );
  });
  for (final exo in [false, true]) {
    test(
      '${exo ? 'ExoPlayer' : 'MPV'} opens with cold preferences and refreshes headers at the same session/offset',
      () async {
        var now = DateTime.utc(2026, 10, 10);
        var rotations = 0;
        final reports = <Map<String, dynamic>>[];
        final auth = TedAuth(
          store: MemoryStore(),
          now: () => now,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/login')) return response(pair(now));
            if (request.url.path.endsWith('/refresh')) {
              rotations++;
              return response(pair(now, suffix: 'b'));
            }
            final events = (jsonDecode(request.body)['events'] as List).cast<Map<String, dynamic>>();
            reports.addAll(events);
            return response({
              'events': [
                for (final event in events) {'id': event['id'], 'outcome': 'applied', 'duplicate': false},
              ],
            });
          }),
        );
        addTearDown(auth.close);
        await auth.login('https://ted.example', 'fixture', '', 'Fixture');
        final calls = <MethodCall>[];
        final channel = exo ? 'com.plezy/exo_player' : 'com.plezy/mpv_player';
        await withMockPlayerChannels(
          methodChannelName: channel,
          eventChannelName: '$channel/events',
          methodHandler: (call) async {
            calls.add(call);
            return call.method == 'initialize' ? true : null;
          },
          testBody: () async {
            final Player player = exo ? PlayerAndroid() : PlayerNative();
            final playback = TedPlayback(
              TedClient(auth),
              player,
              const TedPlaybackSession(sessionId, TedMediaIdentity('movie', 'tt1234567'), mediaPath, 100000, 10000),
            );
            try {
              await playback.open();
              (player as dynamic).handlePlayerEvent('file-loaded', null);
              (player as dynamic).handlePropertyChange('duration', 120.0);
              await Future<void>.delayed(Duration.zero);
              expect(playback.durationMs, 100000);
              await playback.flush();
              now = now.add(const Duration(minutes: 11));
              await playback.seek(const Duration(seconds: 40));
              expect(rotations, 0, reason: 'a local control must not reopen on API token expiry');
              expect(
                calls
                    .where(
                      (call) =>
                          call.method == 'open' ||
                          call.method == 'command' && (call.arguments as Map)['args'][0] == 'loadfile',
                    )
                    .length,
                1,
              );
              await playback.reconnect();
              expect(rotations, 1);
              if (exo) {
                final opens = calls.where((call) => call.method == 'open').toList();
                expect(opens.length, 2);
                final current = opens.last.arguments as Map;
                expect(current['uri'], 'https://ted.example$mediaPath');
                expect(current['headers'], {
                  'Authorization': 'Bearer ted_a_${'b' * 43}',
                  'X-Teddy-Compatibility-Major': '0',
                  'X-Teddy-Compatibility-Version': '0.3',
                });
                expect(current['startPositionMs'], 40000);
              } else {
                final loads = calls
                    .where((call) => call.method == 'command' && (call.arguments as Map)['args'][0] == 'loadfile')
                    .toList();
                expect(loads.length, 2);
                expect((loads.last.arguments as Map)['args'][1], 'https://ted.example$mediaPath');
                final headers = calls
                    .where((call) => call.method == 'command' && (call.arguments as Map)['args'][0] == 'change-list')
                    .toList();
                expect(
                  headers.reversed.take(3).map((call) => (call.arguments as Map)['args'].last),
                  containsAll(['Authorization: Bearer ted_a_${'b' * 43}', 'X-Teddy-Compatibility-Major: 0']),
                );
                final starts = calls
                    .where((call) => call.method == 'setProperty' && (call.arguments as Map)['name'] == 'start')
                    .toList();
                expect((starts.last.arguments as Map)['value'], '40.0');
              }
              (player as dynamic).handlePlayerEvent('file-loaded', null);
              await Future<void>.delayed(Duration.zero);
              await playback.stop();
              expect(reports.map((event) => event['kind']), ['start', 'progress', 'stop']);
              expect(reports.map((event) => event['sequence']), [1, 2, 3]);
              expect(reports.every((event) => event['session_id'] == sessionId), true);
              expect(reports.every((event) => event['origin'] == 'live'), true);
            } finally {
              await playback.closePlayer();
            }
          },
        );
      },
    );
  }
  test('add-on duration is discovered and authenticated sidecars survive natural completion', () async {
    final now = DateTime.utc(2026, 10, 10);
    final reports = <Map<String, dynamic>>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        final events = (jsonDecode(request.body)['events'] as List).cast<Map<String, dynamic>>();
        reports.addAll(events);
        return response({
          'events': [
            for (final event in events) {'id': event['id'], 'outcome': 'applied', 'duplicate': false},
          ],
        });
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture');
    final calls = <MethodCall>[];
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        calls.add(call);
        if (call.method == 'getProperty') {
          return switch ((call.arguments as Map)['name']) {
            'eof-reached' => 'yes',
            'seeking' => 'no',
            'time-pos' => '120.0',
            'duration' => '120.0',
            _ => null,
          };
        }
        return call.method == 'initialize' ? true : null;
      },
      testBody: () async {
        final player = PlayerNative();
        final playback = TedPlayback(
          TedClient(auth),
          player,
          const TedPlaybackSession(
            sessionId,
            TedMediaIdentity('movie', 'tt1234567'),
            mediaPath,
            0,
            10000,
            subtitles: [TedSubtitle('/api/client/v1/playback/sessions/$sessionId/subtitles/0', 'eng', 'English')],
          ),
        );
        try {
          await playback.open();
          player.handlePlayerEvent('start-file', null);
          player.handlePlayerEvent('file-loaded', null);
          await Future<void>.delayed(Duration.zero);
          await playback.flush();
          expect(reports.single['duration_ms'], 0);
          expect(reports.single['position_ms'], 10000);
          expect(playback.completedNaturally, false);
          player.handlePlayerEvent('playback-restart', {'positionSeconds': 10.0});
          player.handlePropertyChange('duration', 120.0);
          await Future<void>.delayed(Duration.zero);
          expect(playback.durationMs, 120000);
          expect(playback.sidecars.single.id, contains('https://ted.example/api/client/v1/playback/sessions/'));
          final loads = calls
              .where((call) => call.method == 'command' && (call.arguments as Map)['args'][0] == 'loadfile')
              .toList();
          expect((loads.single.arguments as Map)['args'].last, contains('sub-files='));
          expect(
            (loads.single.arguments as Map)['args'].last,
            contains('/api/client/v1/playback/sessions/$sessionId/subtitles/0'),
          );
          player.handlePropertyChange('track-list', [
            {'type': 'audio', 'id': 1, 'lang': 'eng'},
            {
              'type': 'sub',
              'id': 2,
              'external': true,
              'external-filename': 'https://ted.example/api/client/v1/playback/sessions/$sessionId/subtitles/0',
            },
          ]);
          await Future<void>.delayed(Duration.zero);
          final selections = calls
              .where((call) => call.method == 'setProperty' && (call.arguments as Map)['name'] == 'sid')
              .toList();
          expect((selections.last.arguments as Map)['value'], '2');
          player.handlePropertyChange('time-pos', 120.0);
          player.handlePropertyChange('eof-reached', true);
          await Future<void>.delayed(Duration.zero);
          await playback.stop();
          expect(reports.last['kind'], 'stop');
          expect(reports.last['duration_ms'], 120000);
          expect(reports.last['natural_eof'], true);
          expect(playback.completedNaturally, true);
          expect(reports.map((e) => e['sequence']), [1, 2]);
        } finally {
          await playback.closePlayer();
        }
      },
    );
  });
  test('a video reload retains failed reports until exact replay is acknowledged', () async {
    final now = DateTime.utc(2026, 10, 10);
    var unavailable = true;
    final bodies = <String>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        if (request.method == 'GET') return response({'code': 'not_found'}, 404);
        bodies.add(request.body);
        if (unavailable) return response({'error': 'unavailable'}, 503);
        final events = (jsonDecode(request.body)['events'] as List).cast<Map<String, dynamic>>();
        return response({
          'events': [
            for (final event in events) {'id': event['id'], 'outcome': 'applied', 'duplicate': true},
          ],
        });
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture');
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async => call.method == 'initialize' ? true : null,
      testBody: () async {
        final player = PlayerNative();
        final playback = TedPlayback(
          TedClient(auth),
          player,
          const TedPlaybackSession(sessionId, TedMediaIdentity('movie', 'tt1234567'), mediaPath, 100000, 10000),
        );
        try {
          await playback.open();
          player.handlePlayerEvent('file-loaded', null);
          await Future<void>.delayed(Duration.zero);
          await expectLater(playback.flush(), throwsA(isA<TedFailure>()));
          expect(playback.failure?.code, 'unavailable');
          final original = bodies.first;
          player.handlePlayerEvent('file-loaded', null);
          await Future<void>.delayed(Duration.zero);
          expect(playback.failure?.code, 'unavailable');
          unavailable = false;
          await playback.flush();
          expect(playback.failure, isNull);
          expect(bodies.every((body) => body == original), true);
          expect((jsonDecode(original)['events'] as List).single['sequence'], 1);
          await playback.stop();
          expect((jsonDecode(bodies.last)['events'] as List).single['sequence'], 2);
        } finally {
          await playback.closePlayer();
        }
      },
    );
  });

  test('pending playback stays with its user/server and can sync after a fresh family sign-in', () async {
    final now = DateTime.utc(2026, 10, 10);
    var unavailable = true;
    final bodies = <String>[];
    final devices = <String>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          final login = jsonDecode(request.body);
          devices.add(login['device_id'] as String);
          return response(
            pair(
              now,
              suffix: devices.length == 1 ? 'a' : 'b',
              familyId: devices.length == 1
                  ? '11111111-1111-4111-8111-111111111111'
                  : '22222222-2222-4222-8222-222222222222',
              userId: login['username'] == 'other' ? 2 : 1,
            ),
          );
        }
        expect(request.url.host, 'ted.example');
        if (request.method == 'GET') return response({'code': 'not_found'}, 404);
        bodies.add(request.body);
        if (unavailable) return response({'error': 'unavailable'}, 503);
        final events = (jsonDecode(request.body)['events'] as List).cast<Map<String, dynamic>>();
        return response({
          'events': [
            for (final event in events) {'id': event['id'], 'outcome': 'applied', 'duplicate': true},
          ],
        });
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Fixture');
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async => call.method == 'initialize' ? true : null,
      testBody: () async {
        final player = PlayerNative();
        final playback = TedPlayback(
          TedClient(auth),
          player,
          const TedPlaybackSession(sessionId, TedMediaIdentity('movie', 'tt1234567'), mediaPath, 100000, 10000),
        );
        try {
          await playback.open();
          player.handlePlayerEvent('file-loaded', null);
          await Future<void>.delayed(Duration.zero);
          await expectLater(playback.flush(), throwsA(isA<TedFailure>()));
          final attempts = bodies.length;
          unavailable = false;
          await auth.login('https://ted.example', 'other', '', 'Fixture');
          await expectLater(playback.flush(), signInRequired);
          await auth.login('https://other.example', 'fixture', '', 'Fixture');
          await expectLater(playback.flush(), signInRequired);
          expect(bodies.length, attempts);
          await auth.login('https://ted.example', 'fixture', '', 'Fixture');
          await playback.flush();
          expect(auth.familyId, '22222222-2222-4222-8222-222222222222');
          expect(playback.failure, isNull);
          expect(devices.toSet().length, 1);
          expect(bodies.every((body) => body == bodies.first), true);
          await playback.stop();
        } finally {
          await playback.closePlayer();
        }
      },
    );
  });

  test('native opaque tokens are redacted even without registration', () {
    for (final token in ['ted_a_${'a' * 43}', 'ted_r_${'b' * 43}']) {
      expect(LogRedactionManager.redact('unexpected native error: $token'), 'unexpected native error: [REDACTED]');
    }
  });
}
