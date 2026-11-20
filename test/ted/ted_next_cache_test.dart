import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_media_transport.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_next_cache.dart';
import 'ted_media_transport_test.dart' show RelayFixture;
import 'ted_playback_test.dart' show sessionId, mediaPath;

const identity = TedMediaIdentity('movie', 'tt1234567');

class DirectHttp extends HttpOverrides {}

const session = TedPlaybackSession(sessionId, identity, mediaPath, 100000, 80000);
TedCachePlan plan() => const TedCachePlan(
  size: 256 << 10,
  etag: '"same-file"',
  resumeMs: 80000,
  durationMs: 100000,
  start: 64 << 10,
  end: 128 << 10,
  aheadBytes: 64 << 10,
  backBytes: 32 << 10,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cached playback uses retained bytes after fresh authorization, with forward before backward',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final f = await RelayFixture.create();
      addTearDown(f.close);
      final cache = TedNextByteCache(identity, plan());
      addTearDown(cache.dispose);
      final warming = TedPlaybackRelay(f.auth, session, cache: cache);
      addTearDown(warming.close);
      await warming.preCache();
      expect(cache.ready, true);
      expect(cache.bytes, lessThanOrEqualTo(96 << 10));
      final expected = plan().ranges.map((r) => 'bytes=${r.$1}-${r.$2}').toList();
      expect(f.calls.map((c) => c.$2).toList(), expected);
      final player = TedPlaybackRelay(f.auth, session, cache: cache);
      addTearDown(player.close);
      final before = f.calls.length;
      final out = await f.get(target: await player.open(), range: 'bytes=65536-85000');
      final bytes = await out.fold<List<int>>([], (all, b) => all..addAll(b));
      expect(bytes, f.payload.sublist(65536, 85001));
      expect(f.calls.skip(before).map((c) => c.$1), ['HEAD']);
      expect(f.errors, isEmpty);
    }, DirectHttp()),
  );
  test(
    'changed representation is refused before any cached byte is delivered',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final f = await RelayFixture.create();
      addTearDown(f.close);
      final cache = TedNextByteCache(identity, plan());
      addTearDown(cache.dispose);
      final warming = TedPlaybackRelay(f.auth, session, cache: cache);
      addTearDown(warming.close);
      await warming.preCache();
      f.changed = 'etag';
      final player = TedPlaybackRelay(f.auth, session, cache: cache);
      addTearDown(player.close);
      final out = await f.get(target: await player.open(), range: 'bytes=65536-85000');
      expect(out.statusCode, 502);
      expect(await out.fold<List<int>>([], (all, b) => all..addAll(b)), isEmpty);
    }, DirectHttp()),
  );
  test('overlaps spend the budget once, pressure evicts speculation and a changed resume cannot adopt it', () {
    var evictions = 0;
    final cache = TedNextByteCache(identity, plan(), onEvicted: () => evictions++);
    addTearDown(cache.dispose);
    cache.put(100, List.filled(100, 1));
    cache.put(150, List.filled(100, 1));
    expect(cache.bytes, 150);
    expect(cache.covers(100, 249), true);
    expect(cache.matches(session, 80000), true);
    expect(cache.matches(session, 75000), false);
    cache.didHaveMemoryPressure();
    expect(evictions, 1);
    expect(cache.bytes, 0);
    expect(cache.ready, false);
    expect(cache.read(100, 249), isNull);
  });
  test('file start and resume windows remain within both budgets without invented backward bytes', () {
    for (final start in [0, 100, 10000, 65536, 200000]) {
      final p = TedCachePlan(
        size: 256 << 10,
        etag: '"same-file"',
        resumeMs: start == 0 ? 0 : 80000,
        durationMs: 100000,
        start: start,
        end: 262143,
        aheadBytes: 64 << 10,
        backBytes: 32 << 10,
      );
      final cache = TedNextByteCache(identity, p);
      addTearDown(cache.dispose);
      for (final r in p.ranges) {
        cache.put(r.$1, List.filled(r.$2 - r.$1 + 1, 1));
      }
      expect(cache.bytes, lessThanOrEqualTo(96 << 10), reason: 'start=$start');
      if (start == 0) expect(p.ranges.last.$1, 0);
    }
  });
  test('zero resume does not fill a backward window even when the first packet follows container metadata', () {
    for (final resume in [0, 80000]) {
      final p = TedCachePlan(
        size: 256 << 10,
        etag: '"same-file"',
        resumeMs: resume,
        durationMs: 100000,
        start: 64 << 10,
        end: 128 << 10,
        aheadBytes: 64 << 10,
        backBytes: 32 << 10,
      );
      final cache = TedNextByteCache(identity, p);
      addTearDown(cache.dispose);
      for (final range in p.ranges) {
        cache.put(range.$1, List.filled(range.$2 - range.$1 + 1, 1));
      }
      expect(cache.read(40 << 10, 41 << 10) != null, resume > 0);
      expect(cache.read(64 << 10, 65 << 10), isNotNull);
    }
  });
}
