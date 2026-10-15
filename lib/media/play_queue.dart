import 'media_item.dart';

class LocalPlayQueue {
  final List<MediaItem> items;
  final int? currentIndex;
  final bool shuffled;

  const LocalPlayQueue({required this.items, this.currentIndex, this.shuffled = false});
}
