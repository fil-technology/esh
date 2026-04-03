#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ "$LLMCACHE_LAYOUT_MODE" == "repo" ]] || llmcache::die "bootstrap is only available from a source checkout."

BUILD_SWIFT=1
if [[ "${1:-}" == "--no-build" ]]; then
  BUILD_SWIFT=0
fi

llmcache::ensure_dev_venv
llmcache::install_python_deps

mkdir -p "$LLMCACHE_APP_ROOT/dist"

if [[ "$BUILD_SWIFT" -eq 1 ]]; then
  llmcache::build_swift debug
fi

llmcache::export_runtime_env
echo "Bootstrap complete."
echo "python: $(llmcache::python_executable)"
echo "bridge: $(llmcache::bridge_script)"
echo "binary: $(llmcache::swift_binary debug)"
