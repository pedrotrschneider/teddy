import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/transport_keys.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/subtitle_fonts.dart';
import 'ted_playback_test.dart' show ControlFixture, mediaPath;

Future<void> settlePlayback() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<MethodCall> mediaLoads(ControlFixture f) =>
    f.calls.where((call) => call.method == 'command' && (call.arguments as Map)['args'][0] == 'loadfile').toList();

String? latestStart(ControlFixture f) =>
    (f.calls.lastWhere((call) => call.method == 'setProperty' && (call.arguments as Map)['name'] == 'start').arguments
            as Map)['value']
        as String?;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(prepareSubtitleFonts);
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
  });

  test('a queued backward seek fences EOF before another native control releases', () async {
    final f = ControlFixture();
    final entered = Completer<void>();
    final release = Completer<void>();
    Future<void>? selection;
    Future<void>? seek;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'setProperty' &&
            (call.arguments as Map)['name'] == 'aid' &&
            (call.arguments as Map)['value'] == '2') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
        return f.method(call);
      },
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
          await settlePlayback();
          selection = f.playback.selectAudioTrack(f.player.state.tracks.audio.last);
          await entered.future;
          seek = f.playback.seek(const Duration(seconds: 7));
          f.nativeEof = true;
          f.player.handlePropertyChange('time-pos', 100.0);
          f.player.handlePropertyChange('eof-reached', true);
          await settlePlayback();
          expect(f.playback.completedNaturally, false);
          expect(f.reports.where((report) => report['natural_eof'] == true), isEmpty);
          release.complete();
          await Future.wait([selection!, seek!]);
          expect(latestStart(f), '10.0', reason: 'a fresh ordinary seek must retain the current stream');
          f.nativeEof = false;
          f.player.handlePropertyChange('eof-reached', false);
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 7.0});
          await settlePlayback();
          expect(f.playback.positionMs, 7000);
          expect(mediaLoads(f), hasLength(1));
        } finally {
          if (!release.isCompleted) release.complete();
          await Future.wait([?selection, ?seek]);
          await f.close();
        }
      },
    );
  });

  test('an EOF query jumping past the decoded position reconnects instead of completing', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
          await settlePlayback();
          f.nativePosition = 100;
          f.nativeEof = true;
          f.player.handlePropertyChange('eof-reached', true);
          await settlePlayback();
          expect(f.playback.completedNaturally, false);
          expect(mediaLoads(f), hasLength(2));
          expect(latestStart(f), '17.0');
          await f.playback.stop();
          expect(f.reports.last['position_ms'], 17000);
          expect(f.reports.every((report) => report['natural_eof'] == false), true);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('a paused backward frame landing before the seek reply clears loading after acknowledgment', () async {
    final f = ControlFixture();
    final entered = Completer<void>();
    final release = Completer<void>();
    Future<void>? seeking;
    var loadingAtLastNotification = true;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        final result = await f.method(call);
        if (call.method == 'command' && (call.arguments as Map)['args'][0] == 'seek') {
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 7.1});
          entered.complete();
          await release.future;
        }
        return result;
      },
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
          await settlePlayback();
          await f.playback.transport(TransportCommand.pause);
          f.playback.addListener(() => loadingAtLastNotification = f.playback.loading);
          seeking = f.playback.seek(const Duration(seconds: 7));
          await entered.future;
          await settlePlayback();
          release.complete();
          await seeking;
          expect(f.playback.loading, false);
          expect(loadingAtLastNotification, false);
          expect(f.playback.positionMs, 7100);
          expect(f.playback.wantsToPlay, false);
          await f.playback.flush();
          expect(f.reports.last['position_ms'], 7100);
          expect(f.reports.last['natural_eof'], false);
        } finally {
          if (!release.isCompleted) release.complete();
          await seeking;
          await f.close();
        }
      },
    );
  });

  test('late EOF timestamps cannot replace a newly decoded backward landing', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 70.0});
          await settlePlayback();
          await f.playback.seek(const Duration(seconds: 7));
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 7.1});
          await settlePlayback();
          // Both the raw property and its synchronous read can contain the
          // demuxer's EOF timestamp; the last decoded landing is still 7.1s.
          f.player.handlePropertyChange('time-pos', 100.0);
          f.player.handlePropertyChange('eof-reached', true);
          await settlePlayback();
          expect(f.playback.completedNaturally, false);
          expect(mediaLoads(f), hasLength(2));
          expect(latestStart(f), '7.1');
          await f.playback.stop();
          expect(f.reports.last['position_ms'], 7100);
          expect(f.reports.every((report) => report['natural_eof'] == false), true);
        } finally {
          await f.close();
        }
      },
    );
  });

  for (final resume in [false, true]) {
    test('${resume ? 'resume' : 'backward seek'} replaces expired stream credentials before native playback', () async {
      final f = ControlFixture();
      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        methodHandler: f.method,
        testBody: () async {
          try {
            await f.open();
            f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
            await settlePlayback();
            f.now = f.now.add(const Duration(minutes: 11));
            if (resume) {
              await f.playback.transport(TransportCommand.pause);
              await f.playback.transport(TransportCommand.play);
            } else {
              await f.playback.seek(const Duration(seconds: 7));
            }
            expect(f.rotations, 1);
            expect(mediaLoads(f), hasLength(2));
            expect((mediaLoads(f).last.arguments as Map)['args'][1], 'https://ted.example$mediaPath');
            expect(latestStart(f), resume ? '17.0' : '7.0');
            expect(
              f.calls.where((call) => call.method == 'command' && (call.arguments as Map)['args'][0] == 'seek'),
              isEmpty,
            );
            final headers = await f.auth.headers();
            final authorization = f.calls.lastWhere(
              (call) =>
                  call.method == 'command' &&
                  (call.arguments as Map)['args'][0] == 'change-list' &&
                  (call.arguments as Map)['args'][2] == 'append' &&
                  ((call.arguments as Map)['args'][3] as String).startsWith('Authorization: '),
            );
            expect((authorization.arguments as Map)['args'][3], 'Authorization: ${headers['Authorization']}');
            expect(f.playback.completedNaturally, false);
            if (!resume) {
              await f.loaded();
              await settlePlayback();
              await f.playback.flush();
              expect(f.reports.last['kind'], 'progress');
              expect(f.reports.last['position_ms'], 7000);
            }
          } finally {
            await f.close();
          }
        },
      );
    });
  }

  test('resume refreshes an idle connection with unchanged credentials and preserves controls', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
          await settlePlayback();
          await f.playback.selectAudioTrack(f.player.state.tracks.audio.last);
          await f.playback.selectSubtitleTrack(f.player.state.tracks.subtitle.single);
          await f.playback.setRate(1.5);
          await f.playback.transport(TransportCommand.pause);
          f.now = f.now.add(const Duration(seconds: 35));
          await f.playback.transport(TransportCommand.play);
          expect(f.rotations, 0);
          expect(mediaLoads(f), hasLength(2));
          expect(latestStart(f), '17.0');
          expect(f.playback.wantsToPlay, true);
          await f.loaded();
          await settlePlayback();
          for (final entry in {'aid': '2', 'sid': '3', 'speed': '1.5'}.entries) {
            final last = f.calls.lastWhere(
              (call) => call.method == 'setProperty' && (call.arguments as Map)['name'] == entry.key,
            );
            expect((last.arguments as Map)['value'], entry.value);
          }
          expect(f.playback.failure, isNull);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('a short pause with current credentials keeps the read-ahead buffer', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          await f.playback.transport(TransportCommand.pause);
          f.now = f.now.add(const Duration(seconds: 2));
          await f.playback.transport(TransportCommand.play);
          expect(mediaLoads(f), hasLength(1));
          expect(f.rotations, 0);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('a paused seek refreshing the connection is reused by the following resume', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          await f.playback.transport(TransportCommand.pause);
          f.now = f.now.add(const Duration(seconds: 35));
          await f.playback.seek(const Duration(seconds: 7));
          await f.playback.transport(TransportCommand.play);
          expect(mediaLoads(f), hasLength(2));
          expect(latestStart(f), '7.0');
          expect(f.playback.wantsToPlay, true);
          expect(f.playback.completedNaturally, false);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('stop during resume credential refresh prevents reopening or unpausing', () async {
    final f = ControlFixture();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
          await settlePlayback();
          await f.playback.transport(TransportCommand.pause);
          f.now = f.now.add(const Duration(minutes: 11));
          f.releaseRefresh = Completer<void>();
          final resume = f.playback.transport(TransportCommand.play);
          await settlePlayback();
          expect(f.refreshEntered.isCompleted, true);
          final stop = f.playback.stop();
          f.releaseRefresh!.complete();
          await Future.wait([resume, stop]);
          expect(mediaLoads(f), hasLength(1));
          expect(f.reports.where((report) => report['kind'] == 'stop'), hasLength(1));
          expect(f.reports.last['position_ms'], 17000);
          expect(f.reports.every((report) => report['natural_eof'] == false), true);
        } finally {
          if (f.releaseRefresh != null && !f.releaseRefresh!.isCompleted) f.releaseRefresh!.complete();
          await f.close();
        }
      },
    );
  });

  test('a failed proactive resume uses three bounded restarts and retains the selected file', () async {
    final f = ControlFixture();
    var rejectLoads = false;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        final result = await f.method(call);
        if (rejectLoads && call.method == 'command' && (call.arguments as Map)['args'][0] == 'loadfile') {
          throw PlatformException(code: 'LOAD_FAILED');
        }
        return result;
      },
      testBody: () async {
        try {
          await f.open();
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 17.0});
          await settlePlayback();
          await f.playback.transport(TransportCommand.pause);
          f.now = f.now.add(const Duration(seconds: 35));
          rejectLoads = true;
          await f.playback.transport(TransportCommand.play);
          for (var i = 0; i < 100 && f.playback.controlsBusy; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(f.playback.controlsBusy, false);
          expect(mediaLoads(f), hasLength(5), reason: 'initial load, proactive resume, then three recovery attempts');
          expect(
            mediaLoads(f).every((call) => (call.arguments as Map)['args'][1] == 'https://ted.example$mediaPath'),
            true,
          );
          expect(latestStart(f), '17.0');
          expect(f.playback.failure?.code, 'playback_failed');
          expect(f.playback.completedNaturally, false);
          await f.playback.stop();
          expect(f.reports.last['position_ms'], 17000);
          expect(f.reports.every((report) => report['natural_eof'] == false), true);
        } finally {
          await f.close();
        }
      },
    );
  });
}
