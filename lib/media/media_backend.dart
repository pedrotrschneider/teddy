/// Discriminator retained for shared presentation models and existing caches.
enum MediaBackend {
  plex,
  ted;
  String get id => name;
  static MediaBackend fromId(String id) => switch (id) {
    'plex' => MediaBackend.plex,
    'ted' => MediaBackend.ted,
    _ => throw ArgumentError('Unsupported media backend: $id'),
  };
  static MediaBackend fromString(String? id) => fromId(id ?? 'plex');
  bool get usesMediaBrowserApi => false;
}
