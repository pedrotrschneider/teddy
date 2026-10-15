#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/teddy-apple-env.sh" required
library="${1:-}"
if [[ ! -f "$library" ]]; then
  echo 'Pass the existing bundled sqlite3 framework binary to this isolated loader regression.' >&2
  exit 2
fi
test_root="$(mktemp -d "${TMPDIR:-/tmp}/teddy-sqlite-loader.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
xcrun clang -Wall -Wextra -Werror \
  "$project_root/scripts/testdata/teddy-sqlite-loader.c" -o "$test_root/loader-test"
for mode in unchanged replaced versioned; do
  mkdir "$test_root/$mode"
  "$test_root/loader-test" "$library" "$test_root/$mode" "$mode"
done
