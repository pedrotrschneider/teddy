import 'dart:convert';
import 'package:drift/drift.dart';
import '../database/app_database.dart';
import 'ted_client.dart';

/// Last successful shelves, scoped to one server/account/device. They remain
/// useful across restarts and outages; every Home visit refreshes them.
class TedHomeCache {
  final AppDatabase db;
  TedHomeCache(this.db);

  Future<TedHomeRow?> read(String scope, String id) async {
    final row = await db
        .customSelect(
          'SELECT value FROM ted_home_cache WHERE scope=? AND row_id=?',
          variables: [Variable(scope), Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return TedHomeRow.fromJson(Map<String, dynamic>.from(jsonDecode(row.read<String>('value')) as Map));
  }

  Future<void> write(String scope, Map<String, dynamic> data) async {
    final row = TedHomeRow.fromJson(data);
    if (row.unavailable || row.issues.isNotEmpty) return;
    await db.customStatement(
      'INSERT INTO ted_home_cache(scope,row_id,value) VALUES(?,?,?) '
      'ON CONFLICT(scope,row_id) DO UPDATE SET value=excluded.value',
      [scope, row.id, jsonEncode(data)],
    );
  }
}
