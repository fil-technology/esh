#!/usr/bin/env bash
# Build a self-contained llama.cpp for esh's GGUF backend.
#
# Why this exists: Homebrew's llama.cpp splits ggml into a separate formula and
# builds with GGML_BACKEND_DL=ON, so the CLI dlopens its compute backends
# (Metal/CPU/BLAS `.so`) from /opt/homebrew/Cellar/ggml/*/libexec at runtime and
# links non-relocatable dylibs. Bundling that binary into a notarized package
# leaves a clean machine (no Homebrew) with no compute backend — GGUF crashes.
#
# This build is fully static instead: backends compiled in (no dlopen), Metal
# shaders embedded, no libcurl/openssl, no external dylibs. The result is a
# self-contained `llama-completion` (the binary esh's GGUF backend invokes) that
# runs GGUF with Metal acceleration on any Apple Silicon Mac with zero external
# dependencies. (In this pinned release `llama-completion` is the sole non-
# interactive completion binary — upstream dropped the plain `llama-cli` target;
# esh prefers `llama-completion` anyway, so it is all that needs bundling.)
#
# Pinned to the exact upstream revision esh is validated against so the packaged
# runtime is reproducible.
set -euo pipefail

# Pinned llama.cpp release (tag b8660 == Homebrew llama.cpp 8660, the version the
# GGUF backend has been validated against). Override only with a deliberate bump.
LLAMA_CPP_REF="${LLAMA_CPP_REF:-b8660}"
LLAMA_CPP_REPO="${LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"

OUT_DIR="${1:?usage: build-llama.sh <output-bin-dir> [work-dir]}"
WORK_DIR="${2:-${TMPDIR:-/tmp}/esh-llama-build}"

SRC_DIR="$WORK_DIR/llama.cpp-$LLAMA_CPP_REF"
BUILD_DIR="$SRC_DIR/build"

echo "[build-llama] ref=$LLAMA_CPP_REF out=$OUT_DIR work=$WORK_DIR"
mkdir -p "$OUT_DIR" "$WORK_DIR"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  rm -rf "$SRC_DIR"
  # Shallow clone of just the pinned tag to keep the checkout small.
  git clone --depth 1 --branch "$LLAMA_CPP_REF" "$LLAMA_CPP_REPO" "$SRC_DIR"
fi

# Static, self-contained, Metal-accelerated, no dlopen, no curl/openssl.
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_BACKEND_DL=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_ACCELERATE=ON \
  -DGGML_BLAS=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON

# Build the non-interactive completion binary esh invokes for GGUF.
cmake --build "$BUILD_DIR" --config Release --target llama-completion -j"$(sysctl -n hw.ncpu)"

# Locate and copy the built binary (path varies by llama.cpp layout).
found="$(find "$BUILD_DIR" -type f -name llama-completion -perm +111 2>/dev/null | head -1)"
[[ -n "$found" ]] || { echo "[build-llama] ERROR: built binary 'llama-completion' not found under $BUILD_DIR" >&2; exit 1; }
cp "$found" "$OUT_DIR/llama-completion"
chmod +x "$OUT_DIR/llama-completion"
echo "[build-llama] -> $OUT_DIR/llama-completion"

# Assert self-containment: no @rpath/Homebrew/ggml dylib dependencies.
bad="$(otool -L "$OUT_DIR/llama-completion" | tail -n +2 | grep -Ei '@rpath|/opt/homebrew|libggml|libllama|libmtmd' || true)"
if [[ -n "$bad" ]]; then
  echo "[build-llama] ERROR: llama-completion has non-relocatable deps:" >&2
  echo "$bad" >&2
  exit 1
fi

echo "[build-llama] OK — self-contained binaries in $OUT_DIR"
