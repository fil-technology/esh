#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIGURATION="${ESH_BUILD_CONFIGURATION:-${LLMCACHE_BUILD_CONFIGURATION:-debug}}"
esh::prepare_runtime "$CONFIGURATION"

echo "layout: $ESH_LAYOUT_MODE"
echo "app_root: $(esh::app_root)"
echo "payload_root: $(esh::payload_root)"
echo "python: $ESH_PYTHON"
echo "bridge: $ESH_MLX_VLM_BRIDGE"
echo "binary: $(esh::swift_binary "$CONFIGURATION")"
