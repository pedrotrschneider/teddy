import 'ted_models.dart';

const tedRatingNames = ['Absolute trash', 'Very Bad', 'Bad', 'Average', 'Good', 'Very Good', 'Absolute cinema'];
const tedRatingColors = [0xFF851F28, 0xFFBD4248, 0xFFDF777B, 0xFF656D73, 0xFF79BD8D, 0xFF359B65, 0xFF145B3A];
int? tedRating(Map<String, dynamic> data, String key) {
  if (!data.containsKey(key)) throw const TedFailure('invalid_response');
  final value = data[key];
  if (value != null && (value is! int || value < 1 || value > 7)) throw const TedFailure('invalid_response');
  return value as int?;
}

class TedTitlePreferences {
  final bool watchlist;
  final int? rating;
  const TedTitlePreferences(this.watchlist, this.rating);
  factory TedTitlePreferences.fromJson(Map<String, dynamic> data) {
    if (data['watchlist'] is! bool) throw const TedFailure('invalid_response');
    return TedTitlePreferences(data['watchlist'] as bool, tedRating(data, 'user_rating'));
  }
}
