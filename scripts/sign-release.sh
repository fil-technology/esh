#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <release-root>" >&2
  exit 1
fi

RELEASE_ROOT="$1"
IDENTITY="${APPLE_DEVELOPER_ID:-}"

if [[ -z "$IDENTITY" ]]; then
  echo "APPLE_DEVELOPER_ID is required." >&2
  exit 1
fi

[[ -d "$RELEASE_ROOT" ]] || {
  echo "Release root not found: $RELEASE_ROOT" >&2
  exit 1
}

mapfile -t MACHO_FILES < <(
  find "$RELEASE_ROOT" -type f -print0 |
    xargs -0 file |
    awk -F: '/Mach-O/ {print $1}' |
    python3 - <<'PY'
import sys
paths = [line.strip() for line in sys.stdin if line.strip()]
for path in sorted(paths, key=len, reverse=True):
    print(path)
PY
)

if [[ ${#MACHO_FILES[@]} -eq 0 ]]; then
  echo "No Mach-O files found under $RELEASE_ROOT" >&2
  exit 1
fi

for path in "${MACHO_FILES[@]}"; do
  codesign \
    --force \
    --sign "$IDENTITY" \
    --timestamp \
    --options runtime \
    "$path"
done

for path in "${MACHO_FILES[@]}"; do
  codesign --verify --verbose=2 "$path"
done

spctl --assess --type execute --verbose=4 "$RELEASE_ROOT/bin/esh" || true
