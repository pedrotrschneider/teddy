import 'package:flutter/material.dart';

/// Shared inventory for the native sidebar and startup setting.
enum TeddySection {
  search('search', 'Search'),
  home('home', 'Home'),
  discover('discover', 'Discover'),
  ratings('ratings', 'Ratings'),
  downloads('downloads', 'Downloads');

  final String id, label;
  const TeddySection(this.id, this.label);
  IconData get icon => switch (this) {
    search => Icons.search,
    home => Icons.home_outlined,
    discover => Icons.explore_outlined,
    ratings => Icons.rate_review_outlined,
    downloads => Icons.download_outlined,
  };
}
