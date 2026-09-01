#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$VERSION_FILE" ]] || die "VERSION file is missing."

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
# Accept X.Y.Z and SemVer pre-releases like X.Y.Z-rc.1 (used for release candidates).
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "VERSION must use semantic versioning like 0.1.0 or 2.0.0-rc.1."

COMMAND="${1:-show}"

case "$COMMAND" in
  show)
    echo "$VERSION"
    ;;
  tag)
    echo "v$VERSION"
    ;;
  verify-tag)
    TAG="${2:-}"
    [[ -n "$TAG" ]] || die "Usage: scripts/release-version.sh verify-tag <tag>"
    [[ "$TAG" == "v$VERSION" ]] || die "Tag $TAG does not match VERSION $VERSION"
    echo "ok"
    ;;
  *)
    die "Unknown command: $COMMAND"
    ;;
esac
