import 'package:flutter/material.dart';

/// Shared inventory for the native sidebar and startup setting.
enum TeddySection {
  search('search', 'Search'),
  home('home', 'Home'),
  movies('movie', 'Movies'),
  series('series', 'Series'),
  watchlist('watchlist', 'Watch List'),
  ratings('ratings', 'Ratings'),
  downloads('downloads', 'Downloads');

  final String id, label;
  const TeddySection(this.id, this.label);
  IconData get icon => switch (this) {
    search => Icons.search,
    home => Icons.home_outlined,
    movies => Icons.movie_outlined,
    series => Icons.tv,
    watchlist => Icons.bookmark_border,
    ratings => Icons.rate_review_outlined,
    downloads => Icons.download_outlined,
  };
}
