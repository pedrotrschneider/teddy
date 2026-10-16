import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'ted_auth.dart';
import 'ted_local_store.dart';

/// Chooser reads are local. Only the explicitly selected, signed-in connection
/// refreshes its image; unavailable/older servers retain the last good picture.
class TedProfilePictures extends ChangeNotifier {
  final TedLocalStore store;
  final Map<String, Uint8List> _images = {};
  TedAuth? _lastAuth;
  DateTime? _attempt;
  int _generation = 0;
  bool _closed = false;
  TedProfilePictures(this.store);

  Uint8List? operator [](String? scope) => _images[scope];
  Map<String, Uint8List> get images => Map.unmodifiable(_images);

  Future<void> load(Iterable<String> scopes) async {
    final loaded = <String, Uint8List>{};
    for (final scope in scopes) {
      final image = await store.profilePicture(scope);
      if (image != null) loaded[scope] = image;
    }
    if (_closed) return;
    _images
      ..clear()
      ..addAll(loaded);
    notifyListeners();
  }

  Future<void> refresh(TedAuth auth, {required bool Function() current, bool force = false}) async {
    final scope = tedOfflineScope(auth);
    bool active() => !_closed && current() && auth.signedIn && tedOfflineScope(auth) == scope;
    if (scope == null || !active()) return;
    final now = DateTime.now();
    if (!force &&
        identical(auth, _lastAuth) &&
        _attempt != null &&
        now.difference(_attempt!) < const Duration(minutes: 1)) {
      return;
    }
    _lastAuth = auth;
    _attempt = now;
    final generation = ++_generation;
    bool valid() => generation == _generation && active();
    try {
      final response = await auth.profilePicture();
      if (!valid()) return;
      Uint8List? image;
      if (response.statusCode == 200) {
        image = response.bodyBytes;
        if (!_png(image)) return;
        final codec = await ui.instantiateImageCodec(image);
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      } else if (response.statusCode != 204) {
        return;
      }
      if (!valid()) return;
      // Keep the same bytes/ImageCache key when the server picture is unchanged.
      if (image != null && listEquals(_images[scope], image)) return;
      await store.saveProfilePicture(scope, image, valid: valid);
      if (!valid()) return;
      if (image == null) {
        _images.remove(scope);
      } else {
        _images[scope] = image;
      }
      notifyListeners();
    } catch (_) {
      // Cosmetic refresh failure never invalidates offline profiles or reports.
    }
  }

  // Reject unexpected/oversized dimensions before invoking a native decoder.
  static bool _png(Uint8List image) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82];
    if (image.length < 33 || image.length > 512 << 10) return false;
    for (var i = 0; i < signature.length; i++) {
      if (image[i] != signature[i]) return false;
    }
    final dimensions = ByteData.sublistView(image);
    return dimensions.getUint32(16) == 256 && dimensions.getUint32(20) == 256;
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
