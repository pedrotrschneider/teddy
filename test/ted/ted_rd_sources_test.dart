import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_download_plan.dart';
import 'package:plezy/ted/ted_source_models.dart';
import 'package:plezy/ted/ted_sources.dart';

void main() {
  testWidgets('both source pickers share green RD and rainbow account availability badges', (tester) async {
    const a = TedSourceChoice(
      '11111111-1111-4111-8111-111111111111',
      'Torrentio',
      'Release one',
      'Episode 1',
      rdDirectPlay: true,
    );
    const b = TedSourceChoice(
      '22222222-2222-4222-8222-222222222222',
      'Comet',
      'Release two',
      'Episode 1',
      rdDirectPlay: true,
      inRDAccount: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TedSourcePicker(page: const TedSourcePage(false, false, [a, b], [], null))),
      ),
    );
    await tester.pump();
    expect(find.text('RD Direct Play'), findsOneWidget);
    expect(find.text('In RD Account'), findsOneWidget);
    final green = tester.widget<Container>(find.byKey(ValueKey('rd-badge-${a.id}'))).decoration as BoxDecoration;
    final rainbow = tester.widget<Container>(find.byKey(ValueKey('rd-badge-${b.id}'))).decoration as BoxDecoration;
    expect(green.color, const Color(0xff287847));
    expect(rainbow.gradient, isA<LinearGradient>());
    expect(b.withFavorite(true).inRDAccount, true);
    expect(tester.takeException(), isNull);
  });
  test('retained server-verified keys recover a queue without changing media or add-on', () {
    final addon = 'a' * 64, oldKey = 'b' * 64, newKey = 'c' * 64;
    final previous = TedDownloadSource.choice(
      TedSourceChoice(
        '11111111-1111-4111-8111-111111111111',
        'Torrentio',
        'Old',
        '',
        addonId: addon,
        sourceKey: oldKey,
      ),
    );
    final current = TedSourceChoice(
      '22222222-2222-4222-8222-222222222222',
      'Torrentio',
      'New',
      '',
      addonId: addon,
      sourceKey: newKey,
      previousSourceKeys: [oldKey],
    );
    expect(previous.match(TedSourcePage(false, false, [current], [], null)), current);
    final otherAddon = TedSourceChoice(
      current.id,
      'Other',
      'New',
      '',
      addonId: 'd' * 64,
      sourceKey: newKey,
      previousSourceKeys: [oldKey],
    );
    expect(previous.match(TedSourcePage(false, false, [otherAddon], [], null)), isNull);
    expect(previous.match(TedSourcePage(false, false, [current, current], [], null)), isNull);
  });
}
