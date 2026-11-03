import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/transport_keys.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_media_transport.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/subtitle_fonts.dart';
import 'ted_playback_test.dart' show ControlFixture;

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

class HeldTransport implements TedMediaTransport {
  final release = Completer<void>();
  Completer<void>? releaseClose;
  var resumes = 0;
  var closes = 0;
  var reconnecting = false;
  @override
  Future<Uri> open() async => Uri.parse('http://127.0.0.1:34821/fixture/media');
  @override
  void resume() {
    resumes++;
    reconnecting = true;
    unawaited(release.future.then((_) => reconnecting = false));
  }

  @override
  Future<void> close() async {
    closes++;
    if (!release.isCompleted) release.complete();
    await releaseClose?.future;
  }
}

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

  for (final pausedSeconds in [2, 35, 660]) {
    test('resume after $pausedSeconds seconds plays retained frames while transport recovery is held', () async {
      final transport = HeldTransport();
      final f = ControlFixture(mediaTransport: transport);
      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        methodHandler: f.method,
        testBody: () async {
          try {
            await f.open();
            f.player.handlePropertyChange('demuxer-cache-state', {
              'cache-end': 60.0,
              'seekable-ranges': [
                {'start': 0.0, 'end': 60.0},
              ],
            });
            await settlePlayback();
            final cached = f.player.state.bufferRanges;
            await f.playback.transport(TransportCommand.pause);
            f.now = f.now.add(Duration(seconds: pausedSeconds));
            await f.playback.transport(TransportCommand.play);
            expect(transport.resumes, 1);
            expect(transport.reconnecting, true);
            expect(mediaLoads(f), hasLength(1));
            expect(f.player.state.bufferRanges, cached);
            expect(f.playback.loading, false);
            expect(f.playback.wantsToPlay, true);
            expect(f.playback.failure, isNull);
            f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 18.0});
            await settlePlayback();
            expect(f.playback.positionMs, 18000, reason: 'cached frames play before network recovery finishes');
            await f.playback.transport(TransportCommand.play);
            expect(transport.resumes, 1, reason: 'repeated Play is idempotent');
            expect(mediaLoads(f), hasLength(1));
          } finally {
            await f.close();
          }
          expect(transport.closes, 1);
        },
      );
    });
  }

  test('cache exhaustion during a background reconnect shows loading without leaving or reloading', () async {
    final transport = HeldTransport();
    final f = ControlFixture(mediaTransport: transport);
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          await f.playback.transport(TransportCommand.pause);
          await f.playback.transport(TransportCommand.play);
          f.player.handlePropertyChange('paused-for-cache', true);
          await settlePlayback();
          expect(f.playback.loading, true);
          expect(f.playback.completedNaturally, false);
          expect(f.playback.failure, isNull);
          expect(mediaLoads(f), hasLength(1));
          transport.release.complete();
          f.player.handlePropertyChange('paused-for-cache', false);
          f.player.handlePlayerEvent('playback-restart', {'positionSeconds': 18.0});
          await settlePlayback();
          expect(f.playback.loading, false);
          expect(f.playback.positionMs, 18000);
          expect(f.reports.where((report) => report['natural_eof'] == true), isEmpty);
        } finally {
          await f.close();
        }
      },
    );
  });

  test('stop saves viewing without waiting for network retirement and native close starts independently', () async {
    final transport = HeldTransport()..releaseClose = Completer<void>();
    final f = ControlFixture(mediaTransport: transport);
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: f.method,
      testBody: () async {
        try {
          await f.open();
          await f.playback.stop();
          expect(transport.releaseClose!.isCompleted, false);
          expect(f.reports.last['kind'], 'stop');
          expect(f.reports.last['position_ms'], 17000);
          var closed = false;
          final closing = f.close().whenComplete(() => closed = true);
          await settlePlayback();
          expect(f.calls.where((call) => call.method == 'dispose'), hasLength(1));
          expect(closed, false);
          transport.releaseClose!.complete();
          await closing;
          expect(transport.closes, 1);
        } finally {
          if (!transport.releaseClose!.isCompleted) transport.releaseClose!.complete();
          await f.close();
        }
      },
    );
  });
}
