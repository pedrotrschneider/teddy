#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/teddy-apple-env.sh" required
# Native functions can resolve lazily. Replacing a running bundle's dylib can
# map a second SQLite instance, then close the first instance's handle with it.
# Build from an isolated source copy and publish an immutable release instead.
mkdir -p "$project_root/.devbox/teddy-macos-builds" "$project_root/build/releases"
build_workspace="$(mktemp -d "$project_root/.devbox/teddy-macos-builds/build-XXXXXXXX")"
release_dir=""
published=false
cleanup() {
  rm -rf -- "$build_workspace"
  if [[ "$published" != true && -n "$release_dir" ]]; then
    rm -rf -- "$release_dir"
  fi
}
trap cleanup EXIT
rsync -a \
  --exclude=/.git/ --exclude=/.devbox/ --exclude=/.dart_tool/ --exclude=/build/ \
  --exclude=/.flutter-plugins-dependencies --exclude=/.idea/ \
  --exclude=/macos/Flutter/ephemeral/ --exclude=/macos/Pods/ \
  --exclude=/macos/Runner.xcodeproj/xcuserdata/ \
  --exclude=/macos/Runner.xcworkspace/xcuserdata/ \
  --exclude=/ios/Flutter/ephemeral/ --exclude=/ios/Pods/ \
  --exclude=/linux/flutter/ephemeral/ --exclude=/windows/flutter/ephemeral/ \
  "$project_root/" "$build_workspace/source/"
# Seed only SQLite's downloaded binaries, never generated outputs or package
# configuration containing paths to another build. The pinned sqlite3 hook
# checks each cached binary's SHA-256 before reuse and downloads a replacement
# if it does not match. This avoids a needless GitHub request on every build.
sqlite_cache=".dart_tool/hooks_runner/shared/sqlite3/build"
for cached_binary in "$project_root/$sqlite_cache"/download-*/libsqlite3.dylib; do
  if [[ -f "$cached_binary" && ! -L "$cached_binary" ]]; then
    cache_directory="$(basename "$(dirname "$cached_binary")")"
    mkdir -p "$build_workspace/source/$sqlite_cache/$cache_directory"
    cp "$cached_binary" "$build_workspace/source/$sqlite_cache/$cache_directory/"
  fi
done
# Seed bare Swift package repositories, not checkouts/generated workspace state.
# Xcode still resolves the checked-in Package.resolved pins and verifies binary
# artifact checksums. Its global cache can exist yet a new clone still goes to
# GitHub; supplying the previous build's bare repositories avoids that clone.
swift_repositories="$project_root/build/macos/SourcePackages/repositories"
if [[ -d "$swift_repositories" ]]; then
  mkdir -p "$build_workspace/source/build/macos/SourcePackages/repositories"
  rsync -a "$swift_repositories/" "$build_workspace/source/build/macos/SourcePackages/repositories/"
fi
cd "$build_workspace/source"
echo "Apple developer tools: $DEVELOPER_DIR"
xcodebuild -version
if ! xcodebuild -checkFirstLaunchStatus; then
  echo 'Xcode first-launch setup is incomplete. Open Xcode and finish its license/component setup, then retry this build.' >&2
  exit 1
fi
if ! xcrun --sdk macosx --show-sdk-path; then
  echo 'The selected Xcode macOS SDK is unavailable. Finish installing its macOS components, then retry this build.' >&2
  exit 1
fi
pod --version
rsync --version
flutter pub get --enforce-lockfile
flutter pub run build_runner build
# Private local build; no Apple team, notarization, telemetry or upstream updater.
flutter build macos --release --no-pub --target lib/teddy_main.dart \
  --dart-define=ENABLE_UPDATE_CHECK=false --dart-define=ENABLE_SENTRY=false \
  --build-name="$(tr -d '\r\n' < version.txt).0" \
  --dart-define="TEDDY_COMPATIBILITY_MAJOR=$(cut -d. -f1 version.txt)" \
  --dart-define="TEDDY_COMPATIBILITY_VERSION=$(tr -d '\r\n' < version.txt)" \
  --dart-define="TEDDY_RELEASE_VERSION=$(tr -d '\r\n' < version.txt).0-dev"
app="$build_workspace/source/build/macos/Build/Products/Release/Teddy.app"
if [[ ! -d "$app" ]]; then
  echo 'The macOS build did not produce Teddy.app.' >&2
  exit 1
fi
bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"
if [[ "$bundle_id" != com.entertainmentdistrict.teddy ]]; then
  echo 'The built app does not have the expected Teddy bundle identity.' >&2
  exit 1
fi
# Flutter can replace its signed Dart framework after Xcode's incremental
# Runner signing step. Verify every framework first, then refresh only the
# private app's outer ad-hoc seal, preserving its existing entitlements/flags.
for framework in "$app"/Contents/Frameworks/*.framework; do
  /usr/bin/codesign --verify --deep --strict "$framework"
done
/usr/bin/codesign --force --sign - --preserve-metadata=entitlements,requirements,flags "$app"
/usr/bin/codesign --verify --deep --strict "$app"
release_dir="$(mktemp -d "$project_root/build/releases/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")"
rsync -a "$app/" "$release_dir/Teddy.app/"
/usr/bin/codesign --verify --deep --strict "$release_dir/Teddy.app"
published=true
# This index points to the actual immutable path, rather than a mutable app
# symlink that could recreate the same lazy-loading problem after an update.
latest_index="$(mktemp "$project_root/.devbox/teddy-macos-latest.XXXXXXXX")"
printf '%s\n' "$release_dir/Teddy.app" > "$latest_index"
mv -- "$latest_index" "$project_root/.devbox/teddy-macos-latest.txt"
echo "Built: $release_dir/Teddy.app"
