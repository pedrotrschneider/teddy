import 'ted_models.dart';

/// Other accounts' display-only viewing; never personal resume or completion.
class TedUserWatch {
  final int accountId, watched, available;
  final String name, avatarVersion;
  final bool seen;
  final double? progress;
  const TedUserWatch(
    this.accountId,
    this.name,
    this.avatarVersion,
    this.seen,
    this.watched,
    this.available,
    this.progress,
  );
  factory TedUserWatch.fromJson(Map<String, dynamic> json) {
    try {
      final w = json['watch'] as Map;
      final v = TedUserWatch(
        json['account_id'] as int,
        json['name'] as String,
        json['avatar_version'] as String? ?? '',
        w['seen'] as bool,
        w['watched'] as int,
        w['available'] as int,
        (w['progress'] as num?)?.toDouble(),
      );
      if (v.accountId <= 0 ||
          v.name.isEmpty ||
          (v.avatarVersion.isNotEmpty && !RegExp(r'^[a-f0-9]{64}$').hasMatch(v.avatarVersion)) ||
          v.watched < 0 ||
          v.available < v.watched ||
          (v.progress != null && (!v.progress!.isFinite || v.progress! < 0 || v.progress! > 100))) {
        throw const FormatException();
      }
      return v;
    } catch (_) {
      throw const TedFailure('invalid_response');
    }
  }
  Map<String, dynamic> toJson() => {
    'account_id': accountId,
    'name': name,
    'avatar_version': avatarVersion,
    'watch': {'seen': seen, 'watched': watched, 'available': available, 'progress': progress},
  };
}
