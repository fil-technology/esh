#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ "$ESH_LAYOUT_MODE" == "repo" ]] || esh::die "package-release is only available from a source checkout."

VERSION="${1:-$(date +%Y%m%d-%H%M%S)}"
ARTIFACT_NAME="esh-macos-$VERSION"
DIST_DIR="$(esh::repo_root)/dist"
ROOT_DIR="$DIST_DIR/$ARTIFACT_NAME"
PAYLOAD_DIR="$ROOT_DIR/share/esh"
ARCHIVE_PATH="$DIST_DIR/$ARTIFACT_NAME.tar.gz"

rm -rf "$ROOT_DIR" "$ARCHIVE_PATH"
mkdir -p "$ROOT_DIR/bin" "$ROOT_DIR/python" "$PAYLOAD_DIR/Tools" "$PAYLOAD_DIR/scripts/lib"

esh::build_swift release
cp "$(esh::swift_binary release)" "$ROOT_DIR/bin/esh"
cp "$(esh::repo_root)/esh" "$ROOT_DIR/esh"
cp "$(esh::repo_root)/scripts/run.sh" "$PAYLOAD_DIR/scripts/run.sh"
cp "$(esh::repo_root)/scripts/verify-env.sh" "$PAYLOAD_DIR/scripts/verify-env.sh"
cp "$(esh::repo_root)/scripts/lib/common.sh" "$PAYLOAD_DIR/scripts/lib/common.sh"
cp "$(esh::repo_root)/Tools/mlx_vlm_bridge.py" "$PAYLOAD_DIR/Tools/mlx_vlm_bridge.py"
cp "$(esh::repo_root)/Tools/python-requirements.txt" "$PAYLOAD_DIR/Tools/python-requirements.txt"

"$(esh::bootstrap_python)" -m venv "$ROOT_DIR/python"
ESH_LAYOUT_MODE="package" \
ESH_APP_ROOT="$ROOT_DIR" \
ESH_PAYLOAD_ROOT="$PAYLOAD_DIR" \
  esh::install_python_deps

chmod +x "$ROOT_DIR/esh" "$ROOT_DIR/bin/esh" "$PAYLOAD_DIR/scripts/run.sh" "$PAYLOAD_DIR/scripts/verify-env.sh"

(
  cd "$DIST_DIR"
  tar -czf "$ARCHIVE_PATH" "$ARTIFACT_NAME"
)

echo "Packaged release at:"
echo "  $ROOT_DIR"
echo "Archive:"
echo "  $ARCHIVE_PATH"
