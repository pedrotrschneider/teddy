import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_preparing_player.dart';
import 'package:plezy/ted/ted_player_loading.dart';
import 'package:plezy/ted/ted_presentation.dart';
import 'ted_auth_test.dart' show MemoryStore;

void main() {
  testWidgets('loading route opens before validation; Escape prevents a late player from opening', (tester) async {
    final auth = TedAuth(store: MemoryStore());
    addTearDown(auth.close);
    final client = TedClient(auth), session = Completer<TedPlaybackSession>();
    var players = 0;
    const media = TedMediaIdentity('movie', 'tt1234567');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TedPreparingPlayer(
                    session: session.future,
                    metadata: TedPresentation(client).item(const TedTitle(media, 'Title', '', false, 0, 0, false)),
                    player: (_) {
                      players++;
                      return const Text('Actual player');
                    },
                  ),
                ),
              ),
              child: const Text('Play'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TedPlayerLoading), findsOneWidget);
    expect(players, 0);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TedPreparingPlayer>(), isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TedPlayerLoading), findsNothing);
    session.complete(const TedPlaybackSession('11111111-1111-4111-8111-111111111111', media, '/unused', 100000, 0));
    await tester.pump();
    expect(players, 0);
    expect(find.text('Play'), findsOneWidget);
  });
}
