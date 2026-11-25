#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/teddy-apple-env.sh" required
trace_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/teddy-startup-trace-XXXXXXXX")"
trap 'rm -rf -- "$trace_check_dir"' EXIT
xcrun swiftc -module-cache-path "$trace_check_dir/modules" \
  "$project_root/macos/Runner/MpvPlayer/MpvStartupTrace.swift" \
  "$project_root/scripts/checks/test_mpv_startup_trace.swift" \
  -o "$trace_check_dir/check"
"$trace_check_dir/check"
