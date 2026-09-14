#!/usr/bin/env bash
# esh M7 — build the pinned llama.cpp as Vendor/llama.xcframework (macOS + iOS device + iOS Simulator,
# Metal embedded). The xcframework is NOT committed (large, platform-built); Package.swift includes the
# EshLlamaCpp target only when Vendor/llama.xcframework is present. Re-run this to (re)generate it.
#
# Usage: scripts/build-llama-xcframework.sh [work_dir]
set -euo pipefail

# Pinned upstream commit evaluated in M6 / built in M7 (docs/IOS_EMBEDDED_GGUF_EVALUATION.md).
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_COMMIT="4a89937354190cef5a97baf8eeb17336105eb72d"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${1:-$REPO_ROOT/.llama-build}"
SRC="$WORK_DIR/llama.cpp"

mkdir -p "$WORK_DIR"
if [ ! -d "$SRC/.git" ]; then
  git init "$SRC"
  git -C "$SRC" remote add origin "$LLAMA_REPO"
fi
git -C "$SRC" fetch --depth 1 origin "$LLAMA_COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD

# Strip macOS AppleDouble sidecar files (harmless on APFS; break CMake source globs on exFAT volumes).
find "$SRC" -name '._*' -delete 2>/dev/null || true

# Build all Apple slices esh links (macOS so the package builds on macOS; iOS device+sim for the app).
( cd "$SRC" && COPYFILE_DISABLE=1 GGML_METAL_EMBED_LIBRARY=ON ./build-xcframework.sh macos ios-device ios-sim )

# Restrict each slice's module to the C text-generation API (header "llama.h", which #includes the ggml
# headers it needs). This intentionally excludes the umbrella glob — it avoids pulling the C++ `mtmd`
# multimodal headers into the Swift C importer, and avoids importing macOS AppleDouble (`._*.h`) sidecar
# files that appear when building/copying on non-APFS (e.g. exFAT) volumes.
XCF_SRC="$SRC/build-apple/llama.xcframework"
find "$XCF_SRC" -name '._*' -delete 2>/dev/null || true
for slice in "$XCF_SRC"/*/llama.framework/Modules/module.modulemap; do
  [ -f "$slice" ] || continue
  cat > "$slice" <<'MODMAP'
framework module llama {
    header "llama.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
    export *
}
MODMAP
done

rm -rf "$REPO_ROOT/Vendor/llama.xcframework" "$REPO_ROOT/Vendor/esh_llama.xcframework"
mkdir -p "$REPO_ROOT/Vendor"
cp -R "$XCF_SRC" "$REPO_ROOT/Vendor/llama.xcframework"

# rc.4 — coexistence: rename the upstream `llama.framework`/module `llama` to esh-private
# `esh_llama.framework`/module `esh_llama` (+ install name + bundle ids, ad-hoc re-sign) so EshLlamaCpp can
# be linked into the same app as another llama.cpp consumer (e.g. LLM.swift). This is a deterministic
# post-build transform on the same pinned bits; see scripts/namespace-llama-xcframework.sh.
"$REPO_ROOT/scripts/namespace-llama-xcframework.sh" \
  "$REPO_ROOT/Vendor/llama.xcframework" "$REPO_ROOT/Vendor/esh_llama.xcframework"
rm -rf "$REPO_ROOT/Vendor/llama.xcframework"
echo "Built Vendor/esh_llama.xcframework from llama.cpp @ $LLAMA_COMMIT (namespaced esh_llama; module restricted to llama.h)"
