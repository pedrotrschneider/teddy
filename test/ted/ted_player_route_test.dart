import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_episode_navigation.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_player_engine.dart';
import 'package:plezy/ted/ted_player_route.dart';
import 'ted_player_engine_test.dart' show Engine;

const target = TedTitle(TedMediaIdentity('episode', 'tt1234567:1:3'), 'Episode', '', false, 0, 0, false);

class Retirement extends StatefulWidget {
  final VoidCallback retire;
  const Retirement(this.retire, {super.key});
  @override
  State<Retirement> createState() => _RetirementState();
}

class _RetirementState extends State<Retirement> {
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('playing'));
  @override
  void dispose() {
    widget.retire();
    super.dispose();
  }
}

Future<NavigatorState> mount(WidgetTester tester) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.macOS),
      navigatorKey: navigator,
      home: const Scaffold(body: Text('details')),
    ),
  );
  return navigator.currentState!;
}

void main() {
  for (final action in [TedPlayerAction.next, TedPlayerAction.completed]) {
    testWidgets('prepared $action disposes its outgoing page without the exit animation', (tester) async {
      final navigator = await mount(tester);
      var retired = false;
      unawaited(
        navigator.push(
          TedPlayerRoute(
            builder: (_) => Retirement(() => retired = true),
            isPrepared: (value) => value.media == target.media,
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop(TedPlayerExit(action, target: target));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(retired, true);
      expect(find.text('details'), findsOneWidget);
    });
  }

  for (final scenario in [
    (TedPlayerAction.back, true),
    (TedPlayerAction.previous, true),
    (TedPlayerAction.next, false),
  ]) {
    testWidgets('${scenario.$1} prepared=${scenario.$2} retains the normal exit transition', (tester) async {
      final navigator = await mount(tester);
      var retired = false;
      final route = TedPlayerRoute(builder: (_) => Retirement(() => retired = true), isPrepared: (_) => scenario.$2);
      unawaited(navigator.push(route));
      await tester.pumpAndSettle();
      expect(route.reverseTransitionDuration, const Duration(milliseconds: 500));
      navigator.pop(TedPlayerExit(scenario.$1, target: scenario.$1 == TedPlayerAction.back ? null : target));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(retired, false);
      await tester.pumpAndSettle();
      expect(retired, true);
    });
  }

  testWidgets('prepared Next waits for decoder retirement before reusing the engine', (tester) async {
    final navigator = await mount(tester);
    final engine = Engine()..heldStop = Completer<void>();
    final pool = TedPlayerEnginePool(create: (_, _) => engine);
    try {
      final current = await pool.acquire('profile', exo: false, hardware: true);
      var retired = false, acquired = false;
      unawaited(
        navigator.push(
          TedPlayerRoute(
            builder: (_) => Retirement(() {
              retired = true;
              unawaited(pool.release(current, retain: true));
            }),
            isPrepared: (_) => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop(const TedPlayerExit(TedPlayerAction.next, target: target));
      final successor = pool.acquire('profile', exo: false, hardware: true).then((value) {
        acquired = true;
        return value;
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(retired, true);
      expect(acquired, false);
      engine.heldStop!.complete();
      await tester.pump();
      expect(acquired, true);
      expect(await successor, same(current));
      await pool.release(current, retain: false);
    } finally {
      if (!engine.heldStop!.isCompleted) engine.heldStop!.complete();
      // Close in the widget's fake-clock zone, where the pool futures live.
      await pool.close();
    }
  });
}
