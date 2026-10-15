import 'media_filter.dart';

class LibraryFilterResult {
  final List<MediaFilter> filters;
  final Map<String, List<MediaFilterValue>> cachedValues;

  const LibraryFilterResult({required this.filters, required this.cachedValues});

  static const empty = LibraryFilterResult(filters: [], cachedValues: {});
}
