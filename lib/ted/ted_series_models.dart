import 'ted_joint_watch.dart';
import 'ted_user_watch.dart';
import 'ted_models.dart';

class TedSeriesWatch {
  final String version;
  final int count, watched;
  final Map<int, (int, int)> seasonCounts;
  final Map<int, List<TedUserWatch>> userCounts;
  final Map<int, List<TedJointWatch>> jointCounts;
  const TedSeriesWatch(
    this.version,
    this.count,
    this.watched, {
    this.seasonCounts = const {},
    this.userCounts = const {},
    this.jointCounts = const {},
  });
  bool get fullyWatched => count > 0 && watched == count;
  factory TedSeriesWatch.fromJson(Map<String, dynamic> data, String series, {int? season}) {
    try {
      final version = data['version'] as String;
      final items = data['items'] as List;
      final ids = <TedMediaIdentity>{};
      var watched = 0;
      for (final raw in items) {
        final item = raw as Map<String, dynamic>;
        final media = TedMediaIdentity.fromJson(item['media'] as Map<String, dynamic>);
        if (media.kind != 'episode' ||
            media.id.split(':').first != series ||
            (season != null && item['season'] != season) ||
            !ids.add(media) ||
            item['revision'] is! int ||
            (item['revision'] as int) < 0 ||
            item['played'] is! bool) {
          throw const TedFailure('invalid_response');
        }
        if (item['played'] == true) watched++;
      }
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(version) || items.length > 10000) {
        throw const TedFailure('invalid_response');
      }
      final counts = <int, (int, int)>{};
      for (final entry in (data['season_counts'] as Map<String, dynamic>? ?? {}).entries) {
        final seasonNumber = int.parse(entry.key);
        final value = entry.value as Map<String, dynamic>;
        final total = value['total'] as int, completed = value['watched'] as int;
        if (seasonNumber < 0 ||
            seasonNumber > 9999 ||
            total < 0 ||
            completed < 0 ||
            completed > total ||
            (season != null && seasonNumber != season)) {
          throw const TedFailure('invalid_response');
        }
        counts[seasonNumber] = (total, completed);
      }
      final joint = <int, List<TedJointWatch>>{};
      for (final entry in (data['joint_counts'] as Map<String, dynamic>? ?? {}).entries) {
        joint[int.parse(entry.key)] = (entry.value as List)
            .map((v) => TedJointWatch.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList();
      }
      final users = <int, List<TedUserWatch>>{};
      for (final entry in (data['user_counts'] as Map<String, dynamic>? ?? {}).entries) {
        final n = int.parse(entry.key);
        if (n < 0 || n > 9999 || (season != null && n != season)) throw const TedFailure('invalid_response');
        users[n] = (entry.value as List)
            .map((e) => TedUserWatch.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
      return TedSeriesWatch(
        version,
        items.length,
        watched,
        seasonCounts: counts,
        jointCounts: joint,
        userCounts: users,
      );
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
}
