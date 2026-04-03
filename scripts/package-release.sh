#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ "$LLMCACHE_LAYOUT_MODE" == "repo" ]] || llmcache::die "package-release is only available from a source checkout."

VERSION="${1:-$(date +%Y%m%d-%H%M%S)}"
ARTIFACT_NAME="llmcache-macos-$VERSION"
DIST_DIR="$(llmcache::repo_root)/dist"
ROOT_DIR="$DIST_DIR/$ARTIFACT_NAME"
PAYLOAD_DIR="$ROOT_DIR/share/llmcache"
ARCHIVE_PATH="$DIST_DIR/$ARTIFACT_NAME.tar.gz"

rm -rf "$ROOT_DIR" "$ARCHIVE_PATH"
mkdir -p "$ROOT_DIR/bin" "$ROOT_DIR/python" "$PAYLOAD_DIR/Tools" "$PAYLOAD_DIR/scripts/lib"

llmcache::build_swift release
cp "$(llmcache::swift_binary release)" "$ROOT_DIR/bin/llmcache"
cp "$(llmcache::repo_root)/llmcache" "$ROOT_DIR/llmcache"
cp "$(llmcache::repo_root)/scripts/run.sh" "$PAYLOAD_DIR/scripts/run.sh"
cp "$(llmcache::repo_root)/scripts/verify-env.sh" "$PAYLOAD_DIR/scripts/verify-env.sh"
cp "$(llmcache::repo_root)/scripts/lib/common.sh" "$PAYLOAD_DIR/scripts/lib/common.sh"
cp "$(llmcache::repo_root)/Tools/mlx_vlm_bridge.py" "$PAYLOAD_DIR/Tools/mlx_vlm_bridge.py"
cp "$(llmcache::repo_root)/Tools/python-requirements.txt" "$PAYLOAD_DIR/Tools/python-requirements.txt"

"$(llmcache::bootstrap_python)" -m venv "$ROOT_DIR/python"
LLMCACHE_LAYOUT_MODE="package" \
LLMCACHE_APP_ROOT="$ROOT_DIR" \
LLMCACHE_PAYLOAD_ROOT="$PAYLOAD_DIR" \
  llmcache::install_python_deps

chmod +x "$ROOT_DIR/llmcache" "$ROOT_DIR/bin/llmcache" "$PAYLOAD_DIR/scripts/run.sh" "$PAYLOAD_DIR/scripts/verify-env.sh"

(
  cd "$DIST_DIR"
  tar -czf "$ARCHIVE_PATH" "$ARTIFACT_NAME"
)

echo "Packaged release at:"
echo "  $ROOT_DIR"
echo "Archive:"
echo "  $ARCHIVE_PATH"
