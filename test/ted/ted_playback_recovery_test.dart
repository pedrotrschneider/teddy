import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/mpv/font_loader.dart';
import 'package:plezy/mpv/player/player_base.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_playback.dart';
import 'package:plezy/ted/teddy_logs.dart';
import '../test_helpers/io_fakes.dart';
import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_playback_test.dart' show ControlFixture, sessionId, mediaPath;
import 'ted_sources_test.dart' as sources;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previous;
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    previous = PathProviderPlatform.instance;
    root = Directory.systemTemp.createTempSync('teddy-playback-recovery-');
    PathProviderPlatform.instance = FakePathProvider(root);
    SubtitleFontLoader.resetForTesting();
  });
  tearDown(() async {
    await TeddyLogs.close();
    SubtitleFontLoader.resetForTesting();
    PathProviderPlatform.instance = previous;
    root.deleteSync(recursive: true);
  });

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> loaded(PlayerBase player, double position) async {
    player.handlePlayerEvent('start-file', null);
    player.handlePlayerEvent('file-loaded', null);
    player.handlePropertyChange('duration', 100.0);
    player.handlePropertyChange('track-list', [
      {'type': 'audio', 'id': 1, 'lang': 'eng'},
      {'type': 'sub', 'id': 3, 'lang': 'eng', 'codec': 'subrip'},
    ]);
    player.handlePlayerEvent('playback-restart', {'positionSeconds': position});
    await settle();
  }

  for (final backend in ['mpv', 'exoplayer']) {
    test('$backend does not turn permanent source failure into recovery or completion after EOF', () async {
      final f = ControlFixture();
      await f.auth.login('https://ted.example', 'fixture', '', 'Recovery');
      final player = backend == 'mpv' ? f.player : PlayerAndroid();
      final playback = backend == 'mpv'
          ? f.playback
          : TedPlayback(
              TedClient(f.auth),
              player,
              const TedPlaybackSession(sessionId, TedMediaIdentity('movie', 'tt1234567'), mediaPath, 100000, 10000),
            );
      await withMockPlayerChannels(
        methodChannelName: player.methodChannel.name,
        eventChannelName: player.eventChannel.name,
        methodHandler: f.method,
        testBody: () async {
          try {
            await playback.open();
            await loaded(player, 10);
            player.handlePlayerEvent('end-file', {'reason': 'error', 'message': 'HTTP error 422'});
            await settle();
            player.handlePropertyChange('time-pos', 100.0);
            player.handlePropertyChange('eof-reached', true);
            await settle();
            expect(playback.failure?.code, 'source_unsupported');
            expect(playback.completedNaturally, false);
            expect(
              f.calls.where(
                (c) => c.method == 'open' || c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile',
              ),
              hasLength(1),
            );
            await playback.flush();
            expect(f.reports.every((r) => r['natural_eof'] == false), true);
          } finally {
            await playback.closePlayer();
            f.auth.close();
          }
        },
      );
    });

    test('$backend retries the pinned stream three times, retains position/tracks and logs terminal failure', () async {
      final f = ControlFixture();
      await f.auth.login('https://ted.example', 'fixture', '', 'Recovery');
      final player = backend == 'mpv' ? f.player : PlayerAndroid();
      final playback = backend == 'mpv'
          ? f.playback
          : TedPlayback(
              TedClient(f.auth),
              player,
              const TedPlaybackSession(sessionId, TedMediaIdentity('movie', 'tt1234567'), mediaPath, 100000, 10000),
            );
      await TeddyLogs.initialize(root);
      await withMockPlayerChannels(
        methodChannelName: player.methodChannel.name,
        eventChannelName: player.eventChannel.name,
        methodHandler: f.method,
        testBody: () async {
          try {
            await playback.open();
            await loaded(player, 10);
            await playback.selectSubtitleTrack(player.state.tracks.subtitle.single);
            player.handlePropertyChange('time-pos', 37.0);
            await settle();
            for (var i = 0; i < 4; i++) {
              player.handlePlayerEvent('end-file', {
                'reason': 'error',
                'message': 'HTTP error 503 https://private.example/SECRET',
              });
              await settle();
              expect(playback.completedNaturally, false);
              if (i < 3) {
                expect(playback.failure, isNull, reason: 'Recover before showing the error');
                expect(playback.positionMs, 37000);
                await loaded(player, 37);
              }
            }
            final opens = f.calls
                .where(
                  (c) => c.method == 'open' || c.method == 'command' && (c.arguments as Map)['args'][0] == 'loadfile',
                )
                .toList();
            expect(opens, hasLength(4));
            expect(playback.failure?.code, 'playback_failed');
            for (final call in opens.skip(1)) {
              final args = call.arguments as Map;
              expect(call.method == 'open' ? args['uri'] : args['args'][1], 'https://ted.example$mediaPath');
              if (call.method == 'open') expect(args['startPositionMs'], 37000);
            }
            if (backend == 'mpv') {
              final fonts = f.calls.where(
                (c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'sub-fonts-dir',
              );
              expect(fonts, hasLength(1));
              final directory = Directory((fonts.single.arguments as Map)['value'] as String);
              for (final font in SubtitleFontLoader.fonts) {
                expect(File('${directory.path}/${font.fileName}').lengthSync(), font.length);
              }
              final fontWrite = f.calls.indexOf(fonts.single);
              expect(fontWrite, lessThan(f.calls.indexOf(opens.first)));
              final sid = f.calls.lastWhere((c) => c.method == 'setProperty' && (c.arguments as Map)['name'] == 'sid');
              expect((sid.arguments as Map)['value'], '3');
            }
            await playback.flush();
            expect(f.reports.where((r) => r['kind'] == 'start'), hasLength(1));
            expect(f.reports.every((r) => r['natural_eof'] == false), true);
            await TeddyLogs.close();
            final log = await File('${root.path}/logs/teddy.log').readAsString();
            expect(log, contains('phase=player_error backend=$backend'));
            expect(log, contains('phase=recovery_exhausted'));
            expect(log, contains('http_status=503'));
            expect(log, isNot(contains('SECRET')));
          } finally {
            await playback.closePlayer();
            f.auth.close();
          }
        },
      );
    });
  }

  test('repeated reopen command failures also consume the bounded restart budget', () async {
    final f = ControlFixture();
    var loads = 0;
    await withMockPlayerChannels(
      methodChannelName: f.player.methodChannel.name,
      eventChannelName: f.player.eventChannel.name,
      methodHandler: (call) async {
        if (call.method == 'command' && (call.arguments as Map)['args'][0] == 'loadfile') {
          loads++;
          if (loads > 1) throw PlatformException(code: 'LOAD_FAILED', message: 'private diagnostic');
        }
        return f.method(call);
      },
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('end-file', {'reason': 'error', 'message': 'decoder failed'});
          await settle();
          expect(loads, 4);
          expect(f.playback.failure?.code, 'playback_failed');
        } finally {
          await f.close();
        }
      },
    );
  });

  test('session preparation retries transient RD errors with the exact choice and keeps diagnostics private', () async {
    final now = DateTime.utc(2026, 10, 10);
    var reads = 0;
    final bodies = <Map<String, dynamic>>[];
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        reads++;
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return reads < 3
            ? response({'code': 'rd_unavailable', 'error': 'https://private.example/SECRET'}, 503)
            : response(sources.session());
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'Recovery');
    await TeddyLogs.initialize(root);
    final session = await TedClient(
      auth,
    ).createSelectedSession(sources.media, sourceId: sources.sourceId, fromBeginning: true);
    expect(session.id, sources.sessionId);
    expect(reads, 3);
    expect(bodies.every((b) => b['source_id'] == sources.sourceId && b['start_from_beginning'] == true), true);
    await TeddyLogs.close();
    final log = await File('${root.path}/logs/teddy.log').readAsString();
    expect(log, contains('code=rd_unavailable'));
    expect(log, contains('attempt=3'));
    expect(log, isNot(contains('SECRET')));
  });

  test('session cancellation stops recovery and permanent RD refusals retain their specific code', () async {
    for (final code in [
      'rd_rejected',
      'rd_limited',
      'rd_source_pending',
      'source_placeholder',
      'source_archive',
      'rd_unavailable',
    ]) {
      final now = DateTime.utc(2026, 10, 10);
      final abort = Completer<void>();
      var reads = 0;
      final auth = TedAuth(
        store: MemoryStore(),
        now: () => now,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/login')) return response(pair(now));
          reads++;
          if (code == 'rd_unavailable') abort.complete();
          return response(
            {'code': code},
            code == 'rd_limited'
                ? 429
                : code == 'source_archive'
                ? 422
                : 503,
          );
        }),
      );
      try {
        await auth.login('https://ted.example', 'fixture', '', 'Recovery');
        await expectLater(
          TedClient(auth).createSelectedSession(sources.media, sourceId: sources.sourceId, abortTrigger: abort.future),
          throwsA(isA<TedFailure>().having((e) => e.code, 'code', code)),
        );
        expect(reads, 1);
      } finally {
        auth.close();
      }
    }
  });
}
