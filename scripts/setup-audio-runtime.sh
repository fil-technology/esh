#!/usr/bin/env bash
# Provision esh's ISOLATED audio-generation runtime (AudioGen SFX via mlx-audiocraft) in a dedicated venv,
# kept separate from the main esh Python venv so its deps never destabilize the MLX LLM/VLM runtime.
#
# The venv lives on managed external storage (the SSD) because it and the model weights are multi-GB and the
# internal disk is small. The bridge finds it via ESH_AUDIOGEN_PYTHON or the default path below.
#
# Reproducible: pinned interpreter (python3.11) + pinned package. Re-run to rebuild cleanly.
set -euo pipefail

RUNTIME_DIR="${ESH_AUDIO_RUNTIME_DIR:-/Volumes/Sviat SSD/esh-runtime/audio/audiogen-mlx}"
PY_BASE="${ESH_AUDIO_PYTHON:-/opt/homebrew/bin/python3.11}"   # clean, non-anaconda interpreter (>=3.10)
MLX_AUDIOCRAFT_VERSION="${MLX_AUDIOCRAFT_VERSION:-0.1.0}"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 PYTHONUTF8=1 COPYFILE_DISABLE=1

echo "esh audio runtime → $RUNTIME_DIR (base: $PY_BASE)"
[ -x "$PY_BASE" ] || { echo "ERROR: $PY_BASE not found (install python3.11, e.g. 'brew install python@3.11')"; exit 1; }

mkdir -p "$RUNTIME_DIR"
rm -rf "$RUNTIME_DIR/venv"
"$PY_BASE" -m venv "$RUNTIME_DIR/venv"
"$RUNTIME_DIR/venv/bin/pip" install --quiet --upgrade pip
"$RUNTIME_DIR/venv/bin/pip" install --quiet "mlx-audiocraft==${MLX_AUDIOCRAFT_VERSION}"

# exFAT storage creates AppleDouble ._* sidecars; transformers' module scan chokes on them — strip them.
find "$RUNTIME_DIR/venv" -name '._*' -delete 2>/dev/null || true

# Smoke check.
if "$RUNTIME_DIR/venv/bin/python" -c "import mlx_audiocraft, transformers; print('audio runtime OK', 'mlx-audiocraft', mlx_audiocraft.__version__)"; then
  echo
  echo "Installed. Point esh at it with:"
  echo "  export ESH_AUDIOGEN_PYTHON=\"$RUNTIME_DIR/venv/bin/python\""
  echo "First audio.generate downloads facebook/audiogen-medium (~3.6GB) to the configured HF cache."
else
  echo "ERROR: audio runtime smoke check failed"; exit 1
fi
