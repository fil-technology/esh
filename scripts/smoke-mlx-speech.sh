#!/usr/bin/env bash
# Live synth -> transcribe smoke for the mlx_audio speech engines (EshMacCapabilities).
#
# Creates a FRESH Python 3.11 venv (like a first-run user: nothing but pip), then runs the opt-in Swift test
# MLXSpeechLiveSmokeTests, which provisions that venv through EshManagedPythonHost from the SHIPPED manifest,
# synthesizes with the catalog default (Kokoro) via the SDK-bundled bridge, and transcribes the WAV back.
# Also runs a static undefined-name check over both bridge copies (the e4fff2d NameError class).
#
#   scripts/smoke-mlx-speech.sh
#   ESH_MLX_SPEECH_SMOKE_ASSETS="/Volumes/SSD/esh-models" scripts/smoke-mlx-speech.sh   # reuse weights
#   ESH_SMOKE_KEEP_VENV=1 ...                                                            # keep the venv
#
# Needs network on first run (~1 GB: mlx-audio stack + Kokoro + Parakeet weights) and Apple silicon.
set -euo pipefail
cd "$(dirname "$0")/.."

PY311="${ESH_SMOKE_PYTHON311:-$(command -v python3.11 || true)}"
if [[ -z "$PY311" ]]; then
  echo "smoke-mlx-speech: python3.11 not found (set ESH_SMOKE_PYTHON311)" >&2
  exit 2
fi

echo "==> static check: undefined names in the bridge (both copies)"
if ! "$PY311" -m pyflakes --version >/dev/null 2>&1; then
  "$PY311" -m pip install --quiet --disable-pip-version-check --user pyflakes >/dev/null 2>&1 || true
fi
for bridge in Sources/EshMacCapabilities/Resources/bridge/mlx_vlm_bridge.py Tools/mlx_vlm_bridge.py; do
  if "$PY311" -m pyflakes "$bridge" | grep -E "undefined name"; then
    echo "smoke-mlx-speech: undefined name(s) in $bridge" >&2
    exit 1
  fi
done
if ! cmp -s Sources/EshMacCapabilities/Resources/bridge/mlx_vlm_bridge.py Tools/mlx_vlm_bridge.py; then
  echo "smoke-mlx-speech: the SDK-bundled bridge and Tools/mlx_vlm_bridge.py have diverged" >&2
  exit 1
fi

# A SHORT venv path: espeak-ng (Kokoro's G2P) has a ~160-byte data-path buffer (the bridge also guards this).
VENV="${ESH_SMOKE_VENV:-${TMPDIR:-/tmp}/esh-speech-smoke-venv}"
rm -rf "$VENV"
echo "==> fresh venv: $VENV"
"$PY311" -m venv "$VENV"
"$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check --upgrade pip
cleanup() { [[ "${ESH_SMOKE_KEEP_VENV:-0}" == "1" ]] || rm -rf "$VENV"; }
trap cleanup EXIT

echo "==> live smoke (provision from the shipped manifest -> Kokoro synth -> Parakeet transcribe)"
set +e
ESH_MLX_SPEECH_SMOKE_PYTHON="$VENV/bin/python3" \
  swift test --filter MLXSpeechLiveSmokeTests 2>&1 | tee "${TMPDIR:-/tmp}/esh-speech-smoke.log"
status=${PIPESTATUS[0]}
set -e
if grep -q "Test synthesizeThenTranscribeRoundTrip() passed" "${TMPDIR:-/tmp}/esh-speech-smoke.log"; then
  echo "==> smoke PASSED"
else
  echo "==> smoke FAILED (see ${TMPDIR:-/tmp}/esh-speech-smoke.log)" >&2
  status=1
fi
exit "$status"
