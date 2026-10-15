#!/usr/bin/env bash
set -euo pipefail
# Invoke through Devbox. Apple tool selection affects only this child command.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/teddy-apple-env.sh" optional
cd "$project_root"
flutter pub get --enforce-lockfile
flutter pub run build_runner build
dart analyze lib test/ted test/widgets/artwork_retry_test.dart test/services/image_cache_service_test.dart
flutter test --no-pub test/ted test/mpv/player_open_test.dart test/mpv/player_native_bridge_test.dart test/mpv/player_android_rate_test.dart \
  test/media/media_item_test.dart test/media/media_item_labels_test.dart test/media/media_hub_test.dart \
  test/media/stepped_seek_test.dart \
  test/widgets/video_controls_header_test.dart test/widgets/video_controls_first_frame_binding_test.dart \
  test/widgets/video_controls_desktop_click_test.dart test/widgets/video_controls_select_key_test.dart \
  test/widgets/track_sheet_test.dart \
  test/widgets/artwork_retry_test.dart test/widgets/optimized_media_image_test.dart \
  test/widgets/media_card_square_test.dart test/widgets/media_card_grid_spacing_test.dart \
  test/services/image_cache_service_test.dart
