import 'ted_client.dart';
import 'ted_models.dart';

/// Retain personal row ordering; discovery fills remaining slots movie-first.
List<TedTitle> selectTedHomeBanner(List<TedHomeRow> rows) {
  final chosen = <TedTitle>[];
  final seen = <TedMediaIdentity>{};
  List<TedTitle> row(String id) => rows.where((r) => r.id == id).firstOrNull?.titles ?? const [];
  void add(TedTitle item) {
    if (chosen.length < 5 && seen.add(item.media)) chosen.add(item);
  }

  for (final id in ['continue-watching', 'next-up']) {
    for (final item in row(id)) {
      add(item);
      if (chosen.length == 5) return chosen;
    }
  }
  final movies = row('popular-movie'), shows = row('popular-series');
  int movie = 0, show = 0;
  while (chosen.length < 5 && (movie < movies.length || show < shows.length)) {
    while (movie < movies.length && seen.contains(movies[movie].media)) {
      movie++;
    }
    if (movie < movies.length) add(movies[movie++]);
    while (show < shows.length && seen.contains(shows[show].media)) {
      show++;
    }
    if (show < shows.length) add(shows[show++]);
  }
  return chosen;
}
