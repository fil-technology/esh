#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <package-root>" >&2
  exit 1
fi

PACKAGE_ROOT="$1"
LAUNCHER="$PACKAGE_ROOT/esh"
MLX_METALLIB="$PACKAGE_ROOT/bin/mlx.metallib"
VERIFY_ENV="$PACKAGE_ROOT/share/esh/scripts/verify-env.sh"

[[ -d "$PACKAGE_ROOT" ]] || {
  echo "error: package root not found: $PACKAGE_ROOT" >&2
  exit 1
}
[[ -x "$LAUNCHER" ]] || {
  echo "error: packaged launcher is not executable: $LAUNCHER" >&2
  exit 1
}
[[ -s "$MLX_METALLIB" ]] || {
  echo "error: packaged MLX Metal runtime library is missing: $MLX_METALLIB" >&2
  exit 1
}
[[ -x "$VERIFY_ENV" ]] || {
  echo "error: packaged verify-env script is not executable: $VERIFY_ENV" >&2
  exit 1
}

TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/esh-package-smoke.XXXXXX")"
cleanup() {
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

export ESH_HOME="$TMP_HOME/home"

echo "smoke: launcher version"
"$LAUNCHER" version

echo "smoke: package environment"
"$VERIFY_ENV"

echo "smoke: package doctor"
DOCTOR_OUTPUT="$("$LAUNCHER" doctor 2>&1)" || {
  if [[ "$DOCTOR_OUTPUT" == *"libmlx.dylib"* && "$DOCTOR_OUTPUT" == *"objectAtIndex"* ]]; then
    echo "$DOCTOR_OUTPUT" >&2
    echo "warning: package doctor skipped because MLX could not see a Metal GPU device in this environment." >&2
    DOCTOR_OUTPUT=""
  else
    echo "$DOCTOR_OUTPUT" >&2
    exit 1
  fi
}
if [[ -n "${DOCTOR_OUTPUT:-}" ]]; then
  echo "$DOCTOR_OUTPUT"
fi

echo "smoke: recommended models"
"$LAUNCHER" model recommended --profile chat

echo "smoke: empty installs"
"$LAUNCHER" model list

# GGUF runtime self-containment. rc.3 shipped a bundled llama-cli that crashed at
# dyld (missing dylibs) and, deeper, dlopened compute backends from Homebrew — so
# GGUF was broken on any clean machine while this smoke test still passed. Guard
# the packaged binary directly: it must exist, be relocatable (no @rpath/Homebrew/
# ggml/llama deps), and actually launch (proving no missing-library dyld crash).
echo "smoke: bundled llama.cpp runtime (GGUF)"
LLAMA_BIN="$PACKAGE_ROOT/share/esh/bin/llama-server"
[[ -x "$LLAMA_BIN" ]] || {
  echo "error: bundled llama-server is missing or not executable: $LLAMA_BIN" >&2
  exit 1
}
if otool -L "$LLAMA_BIN" | tail -n +2 | grep -Eiq '@rpath|/opt/homebrew|/usr/local/(opt|Cellar)|libggml|libllama|libmtmd|openssl'; then
  echo "error: bundled llama-server has non-relocatable dependencies:" >&2
  otool -L "$LLAMA_BIN" >&2
  exit 1
fi
LLAMA_VERSION_OUT="$(env -i HOME="$TMP_HOME" PATH="/usr/bin:/bin" "$LLAMA_BIN" --version 2>&1)" || {
  # A headless CI runner may lack a usable Metal GPU; the CPU backend is compiled
  # in, so tolerate only GPU-device errors — a missing-dylib dyld crash still fails.
  if [[ "$LLAMA_VERSION_OUT" == *"Library not loaded"* || "$LLAMA_VERSION_OUT" == *"image not found"* ]]; then
    echo "$LLAMA_VERSION_OUT" >&2
    echo "error: bundled llama-server failed to load its libraries (dyld)." >&2
    exit 1
  fi
  echo "$LLAMA_VERSION_OUT" >&2
  echo "warning: bundled llama-server --version returned non-zero (no GPU device in this environment?)." >&2
}
echo "smoke: bundled llama.cpp runtime ok"

echo "smoke: ok"
