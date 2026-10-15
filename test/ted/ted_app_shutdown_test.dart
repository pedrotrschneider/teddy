import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/ted/ted_app_shutdown.dart';
import 'package:plezy/ted/ted_local_store.dart';
import '../test_helpers/prefs.dart';
import 'ted_offline_test.dart' show viewing, event;

void main() {
  setUp(resetSharedPreferencesForTest);

  test(
    'normal exit drains a held write on the production background database and preserves interrupted viewing',
    () async {
      final dir = await Directory.systemTemp.createTemp('teddy-exit-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/offline.sqlite');
      final db = (await AppDatabase.open(databaseFile: file)).database;
      final store = TedLocalStore(db);
      final device = await store.installationDevice();
      final entered = Completer<void>(), release = Completer<void>();
      final lock = db.transaction(() async {
        await db.customSelect('SELECT 1').get();
        entered.complete();
        await release.future;
      });
      await entered.future;
      final write = store.record('fixture', viewing, event(1, kind: 'start'), offline: true);
      final shutdown = TedAppShutdown(closeStorage: store.close);
      var exited = false;
      final exit = shutdown.requestExit().then((result) {
        exited = true;
        return result;
      });
      await Future<void>.delayed(Duration.zero);
      expect(exited, false);
      await expectLater(store.record('fixture', viewing, event(2)), throwsStateError);
      release.complete();
      await lock;
      await write;
      expect(await exit, AppExitResponse.exit);

      final reopened = (await AppDatabase.open(databaseFile: file)).database;
      final recovered = TedLocalStore(reopened);
      addTearDown(recovered.close);
      expect(await recovered.installationDevice(), device);
      await recovered.recoverInterrupted();
      final rows = await reopened.customSelect('SELECT envelope FROM ted_reports ORDER BY ordinal').get();
      final reports = rows.map((row) => jsonDecode(row.read<String>('envelope')) as Map).toList();
      expect(reports.map((report) => report['kind']), ['start', 'stop']);
      expect(reports.last['position_ms'], 21000);
      expect(reports.last['natural_eof'], false);
    },
  );

  test('a timeout keeps storage open and repeated quit requests join the same teardown', () async {
    final release = Completer<void>();
    var stops = 0, services = 0, closes = 0;
    final shutdown =
        TedAppShutdown(
            closeStorage: () async {
              closes++;
            },
          )
          ..stopPlayback = () {
            stops++;
            return release.future;
          }
          ..stopServices = () async {
            services++;
          };
    expect(await shutdown.requestExit(deadline: const Duration(milliseconds: 5)), AppExitResponse.cancel);
    expect(closes, 0);
    final retry = shutdown.requestExit();
    release.complete();
    expect(await retry, AppExitResponse.exit);
    expect([stops, services, closes], [1, 1, 1]);
  });

  test('failed player shutdown cancels exit before closing storage and permits a completed-failure retry', () async {
    var failed = true, closes = 0;
    final shutdown =
        TedAppShutdown(
            closeStorage: () async {
              closes++;
            },
          )
          ..stopPlayback = () async {
            if (failed) throw StateError('held native failure');
          };
    expect(await shutdown.requestExit(), AppExitResponse.cancel);
    expect(closes, 0);
    failed = false;
    expect(await shutdown.requestExit(), AppExitResponse.exit);
    expect(closes, 1);
  });
}
