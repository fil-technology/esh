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

MACHO_FILES=()
while IFS= read -r path; do
  MACHO_FILES+=("$path")
done < <(
  find "$RELEASE_ROOT" -type f -print0 |
    xargs -0 file |
    python3 -c '
import sys

paths = set()
for raw in sys.stdin:
    line = raw.strip()
    if "Mach-O" not in line:
        continue
    path = line.split(":", 1)[0].strip()
    arch_marker = " (for architecture "
    if arch_marker in path:
        path = path.split(arch_marker, 1)[0]
    paths.add(path)

for path in sorted(paths, key=len, reverse=True):
    print(path)
'
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
