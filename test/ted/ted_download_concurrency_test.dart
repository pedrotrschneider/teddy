import 'dart:async';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_download_plan.dart';
import 'package:plezy/ted/ted_downloads.dart';
import 'package:uuid/uuid.dart';
import '../test_helpers/prefs.dart';
import 'ted_bulk_downloads_test.dart' show BulkHarness, episode, hash;

class HeldTransfers {
  final tasks = <DownloadTask>[];
  final gates = <String, Completer<void>>{};
  final counts = <int, Completer<void>>{};
  int active = 0, peak = 0;
  bool releaseNew = false;
  final failures = <int>{};
  Future<void> entered(int n) => tasks.length >= n ? Future.value() : (counts[n] ??= Completer<void>()).future;
  void release(int index) {
    final gate = gates[tasks[index].taskId]!;
    if (!gate.isCompleted) gate.complete();
  }

  void finish() {
    releaseNew = true;
    for (var i = 0; i < tasks.length; i++) {
      release(i);
    }
  }

  Future<bool> cancel(String id) async {
    final gate = gates[id];
    if (gate != null && !gate.isCompleted) gate.complete();
    return true;
  }

  Future<TaskStatusUpdate> transfer(DownloadTask task) async {
    final index = tasks.length;
    tasks.add(task);
    active++;
    if (active > peak) peak = active;
    final gate = gates[task.taskId] = Completer<void>();
    if (releaseNew) gate.complete();
    for (final entry in counts.entries) {
      if (tasks.length >= entry.key && !entry.value.isCompleted) entry.value.complete();
    }
    try {
      await gate.future;
      if (failures.contains(index)) return TaskStatusUpdate(task, TaskStatus.failed, null, null, {}, 500);
      await File(await task.filePath()).writeAsBytes([1, 2, 3, 4]);
      return TaskStatusUpdate(task, TaskStatus.complete, null, null, {
        'content-range': 'bytes 0-3/4',
        'etag': '"ted-${hash(10)}"',
      }, 206);
    } finally {
      active--;
    }
  }
}

Future<void> settled(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), true);
}

Future<void> stored(BulkHarness h, {required int complete, int failed = 0}) async {
  for (var i = 0; i < 300; i++) {
    final files = await h.store.downloads(h.downloads.scope!);
    final queue = await h.downloads.queueEntries();
    if (files.where((v) => v['status'] == 'complete').length == complete &&
        files.where((v) => v['status'] == 'failed').length == failed &&
        queue.every((v) => v['status'] == 'failed')) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Download jobs did not reach their expected durable terminal states');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });
  Future<(BulkHarness, HeldTransfers)> fixture() async {
    final h = await BulkHarness.create(holdWorker: false);
    h.downloads.dispose();
    final held = HeldTransfers();
    h.downloads = TedDownloads(h.client, h.store, h.dir, transferTask: held.transfer, cancelTask: held.cancel);
    addTearDown(() async {
      held.finish();
      await h.close();
    });
    return (h, held);
  }

  Future<Map<String, dynamic>> save(BulkHarness h, int n) async {
    final value = h.saved(episode(n), status: 'paused')
      ..['id'] = const Uuid().v4()
      ..['received'] = 0;
    await h.store.saveDownload(h.downloads.scope!, value);
    return value;
  }

  Future<void> entered(BulkHarness h, HeldTransfers held, int n) => held
      .entered(n)
      .timeout(
        const Duration(seconds: 3),
        onTimeout: () async {
          final queue = await h.downloads.queueEntries(), files = await h.store.downloads(h.downloads.scope!);
          fail(
            'Expected $n starts, got ${held.tasks.length}; sessions=${h.client.sessions.length}; '
            'queue=${queue.map((v) => [v["media"], v["status"], v["error"]]).toList()}; '
            'files=${files.map((v) => [v["media"], v["status"]]).toList()}',
          );
        },
      );

  test('individual and bulk downloads share a live limit; lowering it drains without duplicates', () async {
    final (h, held) = await fixture();
    final single = await save(h, 5);
    final first = h.downloads.resume(single);
    await entered(h, held, 1);
    final candidates = await h.downloads.downloadCandidates(h.client.titles);
    h.client.mapped.addAll(candidates.map((v) => v.title.media.id));
    await h.downloads.enqueuePlan(h.downloads.scope!, [
      for (final c in candidates) TedPlannedDownload(c, const TedDownloadSource.mapped()),
    ]);
    await SettingsService.instance.write(SettingsService.teddyMaxSimultaneousDownloads, 3);
    await entered(h, held, 3);
    h.downloads.pumpQueue();
    h.downloads.pumpQueue();
    expect(held.peak, 3);
    expect(held.tasks, hasLength(3));
    await SettingsService.instance.write(SettingsService.teddyMaxSimultaneousDownloads, 1);
    held.release(0);
    await first;
    expect(held.tasks, hasLength(3), reason: 'Two active copies must finish before admitting another at limit 1');
    held.finish();
    await entered(h, held, 5);
    await stored(h, complete: 5);
    await h.downloads.shutdown();
    expect(held.tasks.map((v) => v.taskId).toSet(), hasLength(5));
    expect(held.peak, 3);
    expect((await h.store.downloads(h.downloads.scope!)).where((v) => v['status'] == 'complete'), hasLength(5));
  });

  test('pausing/removing waiting copies and shutdown do not start them or lose durable checkpoints', () async {
    final (h, held) = await fixture();
    final rows = [for (var n = 1; n <= 3; n++) await save(h, n)];
    rows[1]['status'] = 'failed';
    await h.store.saveDownload(h.downloads.scope!, rows[1]);
    final first = h.downloads.resume(rows[0]);
    await entered(h, held, 1);
    final second = h.downloads.resume(rows[1]), third = h.downloads.resume(rows[2]);
    await settled(() => h.downloads.progress(episode(2).media)?.status == 'queued');
    await h.downloads.pause(rows[1]['id'] as String);
    await second;
    await h.downloads.remove(rows[2]);
    await third;
    expect(held.tasks, hasLength(1));
    final stopping = h.downloads.shutdown();
    await stopping;
    await first;
    expect(held.tasks, hasLength(1));
    final retained = await h.store.downloads(h.downloads.scope!);
    expect(retained, hasLength(2));
    expect(retained.every((v) => v['status'] == 'paused' && v['received'] == 0), true);
    expect(await h.store.pending(h.downloads.scope!), 0);
  });

  test('failed group retries use the cap, preserve selected sessions and leave complete siblings untouched', () async {
    final (h, held) = await fixture();
    await SettingsService.instance.write(SettingsService.teddyMaxSimultaneousDownloads, 2);
    final rows = [for (var n = 1; n <= 4; n++) await save(h, n)];
    for (var i = 0; i < rows.length; i++) {
      rows[i]['status'] = i == 3 ? 'complete' : 'failed';
      if (i == 3) rows[i]['received'] = 4;
      await h.store.saveDownload(h.downloads.scope!, rows[i]);
    }
    await h.downloads.retryFailed({for (var n = 1; n <= 4; n++) episode(n).media});
    await entered(h, held, 2);
    expect(held.tasks, hasLength(2));
    held.failures.add(0);
    held.release(0);
    await entered(h, held, 3);
    expect(held.peak, 2);
    held.finish();
    await stored(h, complete: 3, failed: 1);
    await h.downloads.shutdown();
    final saved = await h.store.downloads(h.downloads.scope!);
    expect(saved.where((v) => v['status'] == 'failed'), hasLength(1));
    expect(saved.where((v) => v['status'] == 'complete'), hasLength(3));
    expect(saved.every((v) => v['session'] == rows[0]['session']), true);
    expect(held.tasks.any((v) => v.taskId == 'teddy-${rows[3]['id']}'), false);
    expect(h.client.sessions, isEmpty, reason: 'Retry must reuse its existing prepared source');
  });
}
