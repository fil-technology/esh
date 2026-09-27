#!/usr/bin/env bash
# Provision esh's EXTERNAL ACE-Step 1.5 music runtime (capability `music.generate`, MIT / commercial-safe).
#
# ACE-Step ships as a git project synced with `uv` — there is NO PyPI package, so (unlike the AudioGen /
# voice-clone engines, which esh pip-provisions into an isolated venv) esh does NOT install this itself. This
# script clones the repo, runs `uv sync` to build its `.venv`, and downloads the checkpoints. esh's bridge then
# discovers the runtime via ESH_ACESTEP_PYTHON + ESH_ACESTEP_HOME (or the default paths this script uses), and
# runs the isolated worker `esh_acestep.py` there.
#
# The checkout + weights are multi-GB, so both default to the external SSD (the internal disk is small). The
# checkout defaults to a path esh's bridge already probes, so after this runs music.generate works with no env.
#
# Reproducible: pinned repo + `uv sync` (uv.lock) + esh's own downloader entrypoints. Re-run to update/repair.
set -euo pipefail

ACE_HOME="${ESH_ACESTEP_DIR:-/Volumes/Sviat SSD/esh-runtime/ace-step-1.5}"          # checkout (bridge probes this)
CKPT_DIR="${ESH_ACESTEP_CHECKPOINTS:-/Volumes/Sviat SSD/esh-models/ace-step/checkpoints}"  # weights (~11GB)
ACE_REPO="${ESH_ACESTEP_REPO:-https://github.com/ACE-Step/ACE-Step-1.5.git}"
LM_MODEL="${ESH_ACESTEP_LM:-acestep-5Hz-lm-0.6B}"   # the 0.6B LM esh_acestep.py uses (fits 32GB; 1.7B is the ACE default)
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 PYTHONUTF8=1 COPYFILE_DISABLE=1

echo "esh ACE-Step runtime → $ACE_HOME"
echo "esh ACE-Step weights → $CKPT_DIR (LM: $LM_MODEL)"

# 1. uv (the ACE-Step project's package manager). Install it non-interactively if absent.
if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found — installing (astral.sh)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # shellcheck disable=SC1090
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  command -v uv >/dev/null 2>&1 || { echo "ERROR: uv install failed — install it manually and re-run"; exit 1; }
fi

# 2. Clone (or update) the ACE-Step checkout.
mkdir -p "$(dirname "$ACE_HOME")"
if [ -d "$ACE_HOME/.git" ]; then
  echo "Updating existing checkout…"
  git -C "$ACE_HOME" pull --ff-only || echo "  (pull skipped — local changes; using existing checkout)"
else
  git clone --depth 1 "$ACE_REPO" "$ACE_HOME"
fi

# 3. Build the ACE-Step venv (torch/MPS + torchcodec/torchao/vector-quantize-pytorch + MLX). uv.lock is pinned.
( cd "$ACE_HOME" && uv sync )
ACE_PY="$ACE_HOME/.venv/bin/python"
[ -x "$ACE_PY" ] || { echo "ERROR: uv sync did not produce $ACE_PY"; exit 1; }

# exFAT storage (the SSD) creates AppleDouble ._* sidecars; Python's module scan chokes on them — strip them.
find "$ACE_HOME/.venv" -name '._*' -delete 2>/dev/null || true

# 4. Download the checkpoints into CKPT_DIR using ACE-Step's own downloader (it owns the repo→layout mapping):
#    ensure_main_model → acestep-v15-turbo DiT + vae + Qwen3-Embedding-0.6B (+ default LM); ensure_lm_model → the
#    0.6B LM esh uses. Honors a Hugging Face token from the environment (HF_TOKEN) or the standard hf cache.
mkdir -p "$CKPT_DIR"
ACESTEP_CHECKPOINTS_DIR="$CKPT_DIR" "$ACE_PY" - "$LM_MODEL" <<'PY'
import sys
from acestep.model_downloader import ensure_main_model, ensure_lm_model, get_checkpoints_dir
ckpt = str(get_checkpoints_dir())
ok, msg = ensure_main_model(ckpt)
print("[main]", msg)
if not ok:
    sys.exit(f"ERROR: main model download failed: {msg}")
ok, msg = ensure_lm_model(sys.argv[1], ckpt)
print("[lm]", msg)
if not ok:
    sys.exit(f"ERROR: LM '{sys.argv[1]}' download failed: {msg}")
print("checkpoints ready at", ckpt)
PY

# 5. Smoke check: the worker's imports resolve in the ACE-Step venv.
if ESH_ACESTEP_HOME="$ACE_HOME" "$ACE_PY" -c "import sys; sys.path.insert(0, '$ACE_HOME'); import acestep.handler, acestep.llm_inference, acestep.inference; print('ACE-Step runtime OK')"; then
  echo
  echo "Installed. esh's bridge auto-discovers this checkout at the default path."
  echo "For the CLI / \`esh web\` (or a non-default location), export:"
  echo "  export ESH_ACESTEP_PYTHON=\"$ACE_PY\""
  echo "  export ESH_ACESTEP_HOME=\"$ACE_HOME\""
  echo "  export ACESTEP_CHECKPOINTS_DIR=\"$CKPT_DIR\"   # the esh SDK passes its own PersistenceRoot path instead"
else
  echo "ERROR: ACE-Step runtime smoke check failed"; exit 1
fi
