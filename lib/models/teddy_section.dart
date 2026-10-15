import 'package:flutter/material.dart';

/// Shared inventory for the native sidebar and startup setting.
enum TeddySection {
  search('search', 'Search'),
  home('home', 'Home'),
  movies('movie', 'Movies'),
  series('series', 'Series'),
  downloads('downloads', 'Downloads');

  final String id, label;
  const TeddySection(this.id, this.label);
  IconData get icon => switch (this) {
    search => Icons.search,
    home => Icons.home_outlined,
    movies => Icons.movie_outlined,
    series => Icons.tv,
    downloads => Icons.download_outlined,
  };
}
