import 'dart:convert';
import 'package:drift/drift.dart';
import '../database/app_database.dart';
import 'ted_models.dart';
import 'ted_source_models.dart';

/// Public picker results only. Authorization and private URLs stay on TED.
class TedSourceCache {
  final AppDatabase db;
  final DateTime Function() now;
  TedSourceCache(this.db, {DateTime Function()? now}) : now = now ?? DateTime.now;
  static const lifetime = Duration(hours: 12);

  Future<Map<String, dynamic>?> read(String scope, TedMediaIdentity media) async {
    final row = await db
        .customSelect(
          'SELECT saved_at,value FROM ted_source_cache WHERE scope=? AND media=?',
          variables: [Variable(scope), Variable(jsonEncode(media.toJson()))],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final age = now().millisecondsSinceEpoch - row.read<int>('saved_at');
    if (age < 0 || age >= lifetime.inMilliseconds) return null;
    final data = Map<String, dynamic>.from(jsonDecode(row.read<String>('value')) as Map);
    TedSourcePage.fromJson(data, media);
    return {...data, '_cached': true};
  }

  Future<void> write(String scope, TedMediaIdentity media, Map<String, dynamic> data) async {
    final page = TedSourcePage.fromJson(data, media);
    // Partial success is useful, but a provider outage must not replace a good
    // result or become a twelve-hour cached failure.
    if (page.lookupUnavailable && (page.choices.isEmpty || await read(scope, media) != null)) return;
    await db.customStatement(
      'INSERT INTO ted_source_cache(scope,media,saved_at,value) VALUES(?,?,?,?) '
      'ON CONFLICT(scope,media) DO UPDATE SET saved_at=excluded.saved_at,value=excluded.value',
      [scope, jsonEncode(media.toJson()), now().millisecondsSinceEpoch, jsonEncode(data)],
    );
    await db.customStatement('DELETE FROM ted_source_cache WHERE saved_at<?', [
      now().subtract(lifetime).millisecondsSinceEpoch,
    ]);
  }

  Future<void> favorite(String scope, String key, bool value) async {
    await db.transaction(() async {
      final rows = await db
          .customSelect('SELECT media,value FROM ted_source_cache WHERE scope=?', variables: [Variable(scope)])
          .get();
      for (final row in rows) {
        final data = jsonDecode(row.read<String>('value')) as Map<String, dynamic>;
        var changed = false;
        for (final source in data['sources'] as List) {
          if (source['favorite_key'] == key) {
            source['favorite'] = value;
            changed = true;
          }
        }
        if (changed) {
          final sources = data['sources'] as List;
          final recents = sources.where((s) => (s['recent_rank'] as int? ?? 0) > 0).toList()
            ..sort((a, b) => (a['recent_rank'] as int).compareTo(b['recent_rank'] as int));
          data['preferred_source'] =
              sources.where((s) => s['favorite'] == true).firstOrNull?['id'] ?? recents.firstOrNull?['id'];
          await db.customStatement('UPDATE ted_source_cache SET value=? WHERE scope=? AND media=?', [
            jsonEncode(data),
            scope,
            row.read<String>('media'),
          ]);
        }
      }
    });
  }
}
