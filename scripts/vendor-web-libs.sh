#!/usr/bin/env bash
# esh 2.1 — Managed Project Runtime, Phase 2: vendor curated browser libraries OFFLINE.
#
# Downloads each pinned library ONCE from its pinned source, verifies its sha256 against the value pinned in
# Sources/EshCore/Capabilities/WebLibRegistry.swift, and stores it under the esh assets cache at
#   <assets>/caches/web-libs/<id>/<version>/<file>
# so generated Tier-B projects can be served the library same-origin with NO live download at request time.
# Re-running is idempotent (skips files already present with the correct hash).
#
# Usage: scripts/vendor-web-libs.sh
set -euo pipefail

# Resolve the assets root the same way esh does: ESH_ASSETS_HOME → storage.json assetsRoot → ~/.esh
assets_root="${ESH_ASSETS_HOME:-}"
if [[ -z "$assets_root" ]]; then
  storage="${ESH_HOME:-$HOME/.esh}/storage.json"
  if [[ -f "$storage" ]]; then
    assets_root="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("assetsRoot",""))' "$storage" 2>/dev/null || true)"
  fi
fi
[[ -z "$assets_root" ]] && assets_root="${ESH_HOME:-$HOME/.esh}"
cache_root="$assets_root/caches/web-libs"
echo "Vendoring web libraries into: $cache_root"

# Pinned library set — keep in sync with WebLibRegistry.all.
#   id | version | filename | sha256 | url
libs=(
  "three|0.160.0|three.module.min.js|3e690ac7d180b0aadf0891bea39eec643e29e2d3e75c99b18689518665f69ba6|https://cdnjs.cloudflare.com/ajax/libs/three.js/0.160.0/three.module.min.js"
)

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

for row in "${libs[@]}"; do
  IFS='|' read -r id version filename sha url <<<"$row"
  dest_dir="$cache_root/$id/$version"
  dest="$dest_dir/$filename"
  if [[ -f "$dest" && "$(sha_of "$dest")" == "$sha" ]]; then
    echo "  ✓ $id@$version/$filename already vendored (hash ok)"
    continue
  fi
  mkdir -p "$dest_dir"
  echo "  ↓ fetching $id@$version/$filename"
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp"
  got="$(sha_of "$tmp")"
  if [[ "$got" != "$sha" ]]; then
    rm -f "$tmp"
    echo "  ✗ integrity mismatch for $id@$version/$filename" >&2
    echo "     expected $sha" >&2
    echo "     got      $got" >&2
    exit 1
  fi
  mv "$tmp" "$dest"
  # Strip any AppleDouble sidecar that copy tools may create.
  rm -f "$dest_dir/._$filename"
  echo "  ✓ vendored $id@$version/$filename (hash verified)"
done

echo "Done. Curated web libraries are vendored offline."
