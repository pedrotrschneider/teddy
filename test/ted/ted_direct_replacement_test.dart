import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/ted/ted_player_engine.dart';
import '../test_helpers/player_streams.dart';
import 'ted_player_engine_test.dart' show Engine;

class ReplacementEngine extends Engine {
  final starts = StreamController<PlayerSourceStarted>.broadcast();
  @override
  late final PlayerStreams streams = emptyPlayerStreams(sourceStarted: starts.stream);
  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    await super.dispose(preserveDisplayMode: preserveDisplayMode);
    await starts.close();
  }
}

void main() {
  testWidgets('late cancellation from an older flow cannot stop a newer handoff on the same core', (tester) async {
    final engine = ReplacementEngine();
    final pool = TedPlayerEnginePool(create: (_, _) => engine);
    final firstOwner = Object(), nextOwner = Object();
    try {
      await pool.acquire('profile', exo: false, hardware: true);
      final first = pool.releaseForReplacement(engine, 1, owner: firstOwner);
      await pool.acquire('profile', exo: false, hardware: true);
      engine.starts.add(PlayerSourceStarted(2));
      await tester.pump();
      await first;
      var retired = false;
      final next = pool.releaseForReplacement(engine, 2, owner: nextOwner).then((_) => retired = true);
      await pool.acquire('profile', exo: false, hardware: true);
      await pool.cancelReplacement(owner: firstOwner);
      expect(engine.stops, 0);
      expect(retired, false);
      expect(pool.replacingSourceId(engine), 2);
      engine.starts.add(PlayerSourceStarted(3));
      await tester.pump();
      await next;
      expect(retired, true);
      expect(engine.stops, 0);
      await pool.release(engine, retain: false);
    } finally {
      await pool.close();
    }
  });
  testWidgets('direct replacement lends the same engine without stopping and retires only on a new source', (
    tester,
  ) async {
    final engine = ReplacementEngine();
    final pool = TedPlayerEnginePool(create: (_, _) => engine);
    try {
      await pool.acquire('profile', exo: false, hardware: true);
      var retired = false;
      final outgoing = pool.releaseForReplacement(engine, 1).then((_) => retired = true);
      final incoming = await pool.acquire('profile', exo: false, hardware: true);
      expect(incoming, same(engine));
      expect(pool.replacingSourceId(engine), 1);
      expect(engine.stops, 0);
      expect(engine.cleared, 0);
      engine.starts.add(PlayerSourceStarted(1));
      await tester.pump();
      expect(retired, false);
      engine.starts.add(PlayerSourceStarted(2));
      await tester.pump();
      await outgoing;
      expect(retired, true);
      expect(pool.replacingSourceId(engine), isNull);
      expect(engine.stops, 0);
      expect(engine.disposals, 0);
      await pool.release(incoming, retain: false);
    } finally {
      await pool.close();
    }
  });

  testWidgets('cancelled replacement fences new admission and transport retirement behind native stop', (tester) async {
    final engine = ReplacementEngine()..heldStop = Completer<void>();
    final pool = TedPlayerEnginePool(create: (_, _) => engine);
    try {
      await pool.acquire('profile', exo: false, hardware: true);
      var retired = false, acquired = false;
      final outgoing = pool.releaseForReplacement(engine, 1).then((_) => retired = true);
      final cancelled = pool.cancelReplacement();
      final incoming = pool.acquire('profile', exo: false, hardware: true).then((value) {
        acquired = true;
        return value;
      });
      await tester.pump();
      expect(engine.stops, 1);
      expect(retired, false);
      expect(acquired, false);
      engine.heldStop!.complete();
      await tester.pump();
      await cancelled;
      await outgoing;
      expect(await incoming, same(engine));
      expect(retired, true);
      expect(engine.cleared, 1);
      await pool.release(engine, retain: false);
    } finally {
      if (!engine.heldStop!.isCompleted) engine.heldStop!.complete();
      await pool.close();
    }
  });

  testWidgets('abandoned replacement times out and expires the normally stopped idle core', (tester) async {
    final engine = ReplacementEngine();
    final pool = TedPlayerEnginePool(
      create: (_, _) => engine,
      replacementLifetime: const Duration(seconds: 1),
      idleLifetime: const Duration(seconds: 2),
    );
    try {
      await pool.acquire('profile', exo: false, hardware: true);
      final outgoing = pool.releaseForReplacement(engine, 1);
      await tester.pump(const Duration(seconds: 1));
      await outgoing;
      expect(engine.stops, 1);
      expect(engine.cleared, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(engine.disposals, 1);
    } finally {
      await pool.close();
    }
  });

  testWidgets('a profile change finishes old source retirement before creating a different engine', (tester) async {
    final old = ReplacementEngine()..heldDispose = Completer<void>();
    final next = ReplacementEngine();
    var creates = 0;
    final pool = TedPlayerEnginePool(create: (_, _) => creates++ == 0 ? old : next);
    try {
      await pool.acquire('old-profile', exo: false, hardware: true);
      final outgoing = pool.releaseForReplacement(old, 1);
      var acquired = false;
      final incoming = pool.acquire('new-profile', exo: false, hardware: true).then((value) {
        acquired = true;
        return value;
      });
      await tester.pump();
      await outgoing;
      expect(old.stops, 1);
      expect(old.disposals, 1);
      expect(creates, 1);
      expect(acquired, false);
      old.heldDispose!.complete();
      await tester.pump();
      expect(await incoming, same(next));
      await pool.release(next, retain: false);
    } finally {
      if (!old.heldDispose!.isCompleted) old.heldDispose!.complete();
      await pool.close();
    }
  });

  testWidgets('shutdown releases an abandoned replacement without waiting for a successor', (tester) async {
    final engine = ReplacementEngine();
    final pool = TedPlayerEnginePool(create: (_, _) => engine);
    await pool.acquire('profile', exo: false, hardware: true);
    final outgoing = pool.releaseForReplacement(engine, 1);
    await pool.close();
    await outgoing;
    expect(engine.stops, 1);
    expect(engine.disposals, 1);
    await expectLater(pool.acquire('profile', exo: false, hardware: true), throwsA(anything));
  });

  testWidgets('Back after borrowing but before opening stops both sessions and leaves no stranded lease', (
    tester,
  ) async {
    final old = ReplacementEngine(), next = ReplacementEngine();
    var creates = 0;
    final pool = TedPlayerEnginePool(create: (_, _) => creates++ == 0 ? old : next);
    try {
      await pool.acquire('profile', exo: false, hardware: true);
      final outgoing = pool.releaseForReplacement(old, 1);
      final unused = await pool.acquire('profile', exo: false, hardware: true);
      await pool.release(unused, retain: false);
      await outgoing;
      expect(old.stops, 1);
      expect(old.disposals, 1);
      final fresh = await pool.acquire('profile', exo: false, hardware: true);
      expect(fresh, same(next));
      await pool.release(fresh, retain: false);
    } finally {
      await pool.close();
    }
  });
}
