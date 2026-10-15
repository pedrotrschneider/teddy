import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_downloads.dart';
import 'package:plezy/ted/ted_download_watch.dart';
import 'package:plezy/ted/ted_local_store.dart';
import 'package:plezy/ted/ted_models.dart';
import '../test_helpers/prefs.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;
import 'ted_download_tree_test.dart' show file;

class PolicyDownloads extends TedDownloads {
  final watches = <TedMediaIdentity, TedDownloadWatch>{};
  PolicyDownloads(super.client, super.store, super.root) : super(cancelTask: (_) async => true);
  @override
  Future<Map<TedMediaIdentity, TedDownloadWatch>> watchStates(List<Map<String, dynamic>> files) async => watches;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });
  test('auto removal considers completion after download, preserves progress and refuses playing copies', () async {
    final root = await Directory.systemTemp.createTemp('teddy-download-policy-');
    addTearDown(() => root.delete(recursive: true));
    final store = TedLocalStore(AppDatabase.forTesting(NativeDatabase.memory()));
    addTearDown(store.close);
    final auth = TedAuth(store: MemoryStore(), client: MockClient((_) async => response(pair(DateTime.now()))));
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'policy test');
    final manager = PolicyDownloads(TedClient(auth), store, root);
    addTearDown(manager.dispose);
    final before = DateTime.utc(2026, 10, 11), after = DateTime.utc(2026, 10, 13);
    for (var i = 1; i <= 3; i++) {
      final media = TedMediaIdentity('episode', 'tt1234567:1:$i');
      final saved = file(manager.scope!, i, media, 'Episode $i');
      await store.saveDownload(manager.scope!, saved);
      await manager.directory(saved['id'] as String).create(recursive: true);
      await File('${manager.directory(saved['id'] as String).path}/media.bin').writeAsBytes(List.filled(10, 1));
      manager.watches[media] = TedDownloadWatch(
        media,
        true,
        i == 2,
        i == 2 ? 1000 : 0,
        10000,
        after,
        i == 1 ? before : after,
      );
    }
    await SettingsService.instance.write(SettingsService.autoRemoveWatchedDownloads, true);
    manager.beginPlaying('44444444-4444-4444-8444-444444444443');
    await manager.applyPolicies();
    expect((await manager.list()).length, 3);
    await expectLater(manager.moveLocation(Directory('${root.path}-other')), throwsA(isA<TedFailure>()));
    manager.endPlaying('44444444-4444-4444-8444-444444444443');
    await manager.applyPolicies();
    expect((await manager.list()).map((v) => v['media']['id']), ['tt1234567:1:2', 'tt1234567:1:1']);
    expect(await File('${root.path}/44444444-4444-4444-8444-444444444443/media.bin').exists(), false);
    expect(await store.installationDevice(), isNotEmpty);
  });
}
