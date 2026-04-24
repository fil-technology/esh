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
"$LAUNCHER" doctor

echo "smoke: recommended models"
"$LAUNCHER" model recommended --profile chat

echo "smoke: empty installs"
"$LAUNCHER" model list

echo "smoke: ok"
