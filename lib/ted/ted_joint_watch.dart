import 'ted_models.dart';

class TedJointWatch {
  final int accountId, watched, available;
  final String name, color;
  final bool seen;
  final double? progress;
  const TedJointWatch(this.accountId, this.name, this.color, this.seen, this.watched, this.available, this.progress);
  factory TedJointWatch.fromJson(Map<String, dynamic> json) {
    try {
      final w = json['watch'] as Map;
      final v = TedJointWatch(
        json['account_id'] as int,
        json['name'] as String,
        json['color'] as String,
        w['seen'] as bool,
        w['watched'] as int,
        w['available'] as int,
        (w['progress'] as num?)?.toDouble(),
      );
      if (v.accountId <= 0 ||
          !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v.color) ||
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
    'color': color,
    'watch': {'seen': seen, 'watched': watched, 'available': available, 'progress': progress},
  };
}
