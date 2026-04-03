#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ "$ESH_LAYOUT_MODE" == "repo" ]] || esh::die "bootstrap is only available from a source checkout."

BUILD_SWIFT=1
if [[ "${1:-}" == "--no-build" ]]; then
  BUILD_SWIFT=0
fi

esh::ensure_dev_venv
esh::install_python_deps

mkdir -p "$ESH_APP_ROOT/dist"

if [[ "$BUILD_SWIFT" -eq 1 ]]; then
  esh::build_swift debug
fi

esh::export_runtime_env
echo "Bootstrap complete."
echo "python: $(esh::python_executable)"
echo "bridge: $(esh::bridge_script)"
echo "binary: $(esh::swift_binary debug)"
