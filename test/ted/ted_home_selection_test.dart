import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_home_selection.dart';
import 'ted_catalog_test.dart' show titleData;

TedTitle media(int n, {String kind = 'movie'}) => TedTitle.fromJson(titleData(kind: kind, id: 'tt${1234560 + n}'));
List<TedHomeRow> rows({
  List<TedTitle> watching = const [],
  List<TedTitle> next = const [],
  List<TedTitle> movies = const [],
  List<TedTitle> shows = const [],
}) => [
  TedHomeRow('continue-watching', watching, false, []),
  TedHomeRow('next-up', next, false, []),
  TedHomeRow('popular-movie', movies, false, []),
  TedHomeRow('popular-series', shows, false, []),
];
void main() {
  test('personal rows have priority and retain their existing order', () {
    final all = List.generate(8, media);
    expect(
      selectTedHomeBanner(rows(watching: all, next: [media(10)])).map((t) => t.media),
      all.take(5).map((t) => t.media),
    );
    expect(
      selectTedHomeBanner(
        rows(watching: all.take(2).toList(), next: all.skip(2).take(2).toList(), movies: [all[4]], shows: [media(10)]),
      ).map((t) => t.media),
      all.take(5).map((t) => t.media),
    );
  });
  test('discovery alternates movie first, including when personal rows are empty', () {
    final movies = List.generate(4, media), shows = List.generate(4, (i) => media(i + 10, kind: 'series'));
    expect(
      selectTedHomeBanner(rows(movies: movies, shows: shows)).map((t) => t.media),
      [movies[0], shows[0], movies[1], shows[1], movies[2]].map((t) => t.media),
    );
    expect(
      selectTedHomeBanner(
        rows(watching: [media(30)], next: [media(31)], movies: movies, shows: shows),
      ).map((t) => t.media),
      [media(30), media(31), movies[0], shows[0], movies[1]].map((t) => t.media),
    );
  });
  test('duplicates do not consume category turns; shortages retain available items', () {
    final movie = media(1), next = media(2), other = media(3), show = media(5, kind: 'series');
    expect(
      selectTedHomeBanner(
        rows(watching: [movie], next: [movie, next], movies: [movie, next, other], shows: [show]),
      ).map((t) => t.media),
      [movie, next, other, show].map((t) => t.media),
    );
    expect(selectTedHomeBanner(rows(movies: List.generate(6, media))).length, 5);
    expect(selectTedHomeBanner(rows()), isEmpty);
  });
}
