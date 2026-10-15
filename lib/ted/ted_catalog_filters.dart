import 'package:flutter/material.dart';

/// The same genre vocabulary as TED's Cinemeta web browser.
const tedCatalogGenres = [
  '',
  'Action',
  'Adventure',
  'Animation',
  'Biography',
  'Comedy',
  'Crime',
  'Documentary',
  'Drama',
  'Family',
  'Fantasy',
  'History',
  'Horror',
  'Mystery',
  'Romance',
  'Sci-Fi',
  'Sport',
  'Thriller',
  'War',
  'Western',
];

class TedCatalogFilters extends StatelessWidget {
  final bool mapped;
  final String watched, genre, catalog;
  final double horizontalInset;
  final ValueChanged<bool> onMapped;
  final ValueChanged<String> onWatched, onGenre, onCatalog;
  const TedCatalogFilters({
    super.key,
    this.horizontalInset = 28,
    required this.mapped,
    required this.watched,
    required this.genre,
    required this.catalog,
    required this.onMapped,
    required this.onWatched,
    required this.onGenre,
    required this.onCatalog,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(horizontalInset, 12, horizontalInset, 12),
    child: Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilterChip(
          key: const ValueKey('catalog-mapped'),
          label: const Text('Mapped'),
          selected: mapped,
          onSelected: onMapped,
        ),
        _select(
          'Watch status',
          'catalog-watched',
          watched,
          const {'all': 'All', 'watched': 'Watched', 'fully': 'Fully Watched', 'partial': 'Partially Watched'},
          onWatched,
          width: 220,
        ),
        _select('Genre', 'catalog-genre', genre, {
          for (final value in tedCatalogGenres) value: value.isEmpty ? 'All genres' : value,
        }, onGenre),
        _select('Catalog', 'catalog-order', catalog, const {
          'popular': 'Popular',
          'new': 'New',
        }, mapped || watched != 'all' ? null : onCatalog),
        if (mapped || watched != 'all') const Text('Saved titles and history, A–Z.'),
      ],
    ),
  );

  Widget _select(
    String label,
    String key,
    String value,
    Map<String, String> values,
    ValueChanged<String>? changed, {
    double width = 180,
  }) => SizedBox(
    width: width,
    child: DropdownButtonFormField<String>(
      key: ValueKey(key),
      initialValue: value,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      isExpanded: true,
      items: [for (final entry in values.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
      onChanged: changed == null
          ? null
          : (next) {
              if (next != null) changed(next);
            },
    ),
  );
}
