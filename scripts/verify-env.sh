#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIGURATION="${LLMCACHE_BUILD_CONFIGURATION:-debug}"
llmcache::prepare_runtime "$CONFIGURATION"

echo "layout: $LLMCACHE_LAYOUT_MODE"
echo "app_root: $(llmcache::app_root)"
echo "payload_root: $(llmcache::payload_root)"
echo "python: $LLMCACHE_PYTHON"
echo "bridge: $LLMCACHE_MLX_VLM_BRIDGE"
echo "binary: $(llmcache::swift_binary "$CONFIGURATION")"

"$(llmcache::swift_binary "$CONFIGURATION")" doctor
