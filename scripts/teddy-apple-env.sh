#!/usr/bin/env bash
# Source only in explicit Teddy build/check commands, never shell initialization.
# Keep Ruby/CocoaPods/Flutter in Devbox while delegating Apple SDK commands to
# the selected full Xcode (or Command Line Tools for Dart-only checks).
teddy_apple_env() {
  local mode="${1:-optional}"
  if [[ "$(uname -s)" != Darwin ]]; then
    if [[ "$mode" == required ]]; then
      echo 'A macOS Teddy build requires a macOS host.' >&2
      return 1
    fi
    return 0
  fi
  local project_root
  project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local selected="${TED_XCODE_DIR:-}"
  if [[ -z "$selected" ]]; then
    if [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
      selected=/Applications/Xcode.app/Contents/Developer
    elif [[ -x "$project_root/.devbox/apple/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
      selected="$project_root/.devbox/apple/Xcode.app/Contents/Developer"
    elif [[ "$mode" != required && -d /Library/Developer/CommandLineTools ]]; then
      selected=/Library/Developer/CommandLineTools
    fi
  fi
  if [[ ! -d "$selected" || ( "$mode" == required && ! -x "$selected/usr/bin/xcodebuild" ) ]]; then
    echo 'Full Xcode is unavailable. Install Xcode from Apple, finish its first-launch setup, or set TED_XCODE_DIR to its Contents/Developer directory.' >&2
    return 1
  fi
  export DEVELOPER_DIR="$selected"
  # Nix SDK/compiler overrides must not select a different Apple SDK during
  # Flutter native hooks. This affects only this explicit command's environment.
  # Xcode must also choose its linker driver: Nix's LD=ld makes Xcode pass
  # compiler flags directly to the raw linker instead of through clang.
  unset SDKROOT CC CXX LD AR AS NM RANLIB STRIP
  local apple_tools="$project_root/.devbox/teddy-apple-tools"
  mkdir -p "$apple_tools"
  local tool
  for tool in xcrun xcodebuild clang clang++ ar as ranlib ld libtool strip nm swift swiftc dsymutil lipo; do
    if [[ -x "/usr/bin/$tool" ]]; then
      ln -sfn "/usr/bin/$tool" "$apple_tools/$tool"
    fi
  done
  export PATH="$apple_tools:$PATH"
}
teddy_apple_env "${1:-optional}"
