import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_player_engine.dart';

class Engine implements Player {
  int stops = 0, disposals = 0, cleared = 0;
  Completer<void>? heldStop;
  Completer<void>? heldDispose;
  bool failStop = false;
  @override
  String get playerType => 'mpv';
  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('stop failed');
    await heldStop?.future;
  }

  @override
  Future<void> clearVideoFrameRate() async {
    cleared++;
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    disposals++;
    await heldDispose?.future;
  }

  @override
  Future<String?> getProperty(String name) async => name == 'demuxer-max-bytes' ? '67108864' : '33554432';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('a successor waits for decoder retirement then borrows the same MPV engine', (tester) async {
    final engine = Engine()..heldStop = Completer<void>();
    var creates = 0;
    final pool = TedPlayerEnginePool(
      create: (_, _) {
        creates++;
        return engine;
      },
    );
    final first = await pool.acquire('profile', exo: false, hardware: true);
    final release = pool.release(first, retain: true);
    var acquired = false;
    final next = pool.acquire('profile', exo: false, hardware: true).then((p) {
      acquired = true;
      return p;
    });
    await tester.pump();
    expect(acquired, false);
    expect(creates, 1);
    expect(engine.disposals, 0);
    engine.heldStop!.complete();
    await release;
    expect(await next, same(first));
    expect(creates, 1);
    expect(engine.cleared, 1);
    expect(await pool.cacheBudget(), (64 << 20, 32 << 20));
    await pool.release(engine, retain: false);
    expect(engine.disposals, 1);
    await pool.close();
  });
  testWidgets('idle engine survives 29 seconds and expires at 30; profile changes cannot reuse it', (tester) async {
    final engines = <Engine>[];
    final pool = TedPlayerEnginePool(
      create: (_, _) {
        final e = Engine();
        engines.add(e);
        return e;
      },
    );
    final first = await pool.acquire('a', exo: false, hardware: true);
    await pool.release(first, retain: true);
    await tester.pump(const Duration(seconds: 29));
    expect(engines.single.disposals, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(engines.single.disposals, 1);
    final second = await pool.acquire('a', exo: false, hardware: true);
    await pool.release(second, retain: true);
    final third = await pool.acquire('b', exo: false, hardware: true);
    expect(identical(second, third), false);
    expect(engines[1].disposals, 1);
    await pool.release(third, retain: false);
    await pool.close();
  });
  testWidgets('a new engine waits for an expired native core to finish disposal', (tester) async {
    final old = Engine()..heldDispose = Completer<void>();
    var creates = 0;
    final pool = TedPlayerEnginePool(create: (_, _) => creates++ == 0 ? old : Engine());
    await pool.acquire('a', exo: false, hardware: true);
    await pool.release(old, retain: true);
    await tester.pump(const Duration(seconds: 30));
    var acquired = false;
    final next = pool.acquire('a', exo: false, hardware: true).then((value) {
      acquired = true;
      return value;
    });
    await tester.pump();
    expect(old.disposals, 1);
    expect(acquired, false);
    expect(creates, 1);
    old.heldDispose!.complete();
    final player = await next;
    expect(creates, 2);
    await pool.release(player, retain: false);
    await pool.close();
  });
  testWidgets('a failed decoder stop retires that core and allows a fresh successor', (tester) async {
    final old = Engine()..failStop = true;
    var creates = 0;
    final pool = TedPlayerEnginePool(create: (_, _) => creates++ == 0 ? old : Engine());
    await pool.acquire('a', exo: false, hardware: true);
    await pool.release(old, retain: true);
    expect(old.disposals, 1);
    final next = await pool.acquire('a', exo: false, hardware: true);
    expect(identical(next, old), false);
    expect(creates, 2);
    await pool.release(next, retain: false);
    await pool.close();
  });
  testWidgets('shutdown fences a successor waiting for a retained engine', (tester) async {
    final engine = Engine();
    final pool = TedPlayerEnginePool(create: (_, _) => engine);
    await pool.acquire('a', exo: false, hardware: true);
    final pending = pool.acquire('a', exo: false, hardware: true);
    final rejected = expectLater(pending, throwsA(isA<TedFailure>()));
    await tester.pump();
    await pool.close();
    await rejected;
    expect(engine.disposals, 1);
  });
}
