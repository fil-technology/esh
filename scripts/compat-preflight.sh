#!/usr/bin/env bash
# Preflight guard for the compat-runtime sweep (esp. AudioGen SFX).
#
# WHY: AudioGen loads T5-large + audiogen-medium (several GB resident). On 2026-09-16 running it on a
# near-full internal disk exhausted macOS swap ("LOW swap space", 14 swapfiles) and starved watchdogd,
# causing a kernel panic + reboot. This gate refuses to launch a heavy run unless there is enough disk
# headroom (so swap can grow) and the model/venv volume is actually mounted, and it caps CPU thread
# oversubscription + MPS memory watermark for whatever command it execs.
#
# USAGE:
#   scripts/compat-preflight.sh                 # checks only; exit 0 if safe, non-zero otherwise
#   scripts/compat-preflight.sh <cmd> [args...] # check, then exec <cmd> with memory-capping env applied
#
# THRESHOLDS (override via env):
#   COMPAT_MIN_INTERNAL_FREE_GB  (default 15)  free space required on the boot/APFS-container volume
#   COMPAT_MIN_ASSETS_FREE_GB    (default 10)  free space required on the model/venv (assets) volume
#   COMPAT_MIN_MEM_FREE_PCT      (default 10)  min system-wide free memory %% (skipped if unavailable)
#   COMPAT_SKIP_ASSETS_CHECK     (default 0)   set 1 to skip the assets-volume checks (native-only runs)
set -euo pipefail

MIN_INTERNAL_FREE_GB="${COMPAT_MIN_INTERNAL_FREE_GB:-20}"
MIN_ASSETS_FREE_GB="${COMPAT_MIN_ASSETS_FREE_GB:-10}"
MIN_MEM_FREE_PCT="${COMPAT_MIN_MEM_FREE_PCT:-10}"
SKIP_ASSETS_CHECK="${COMPAT_SKIP_ASSETS_CHECK:-0}"
STORAGE_JSON="${ESH_STORAGE_JSON:-$HOME/.esh/storage.json}"

fail=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; fail=1; }
ok()   { printf '  ✓ %s\n' "$*"; }

# Free space in whole GiB for the volume containing a path (df -g reports 1-GiB blocks).
free_gib() { df -g "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

echo "== compat preflight =="

# 1) Internal / boot volume headroom — the swap-exhaustion guard.
internal_free="$(free_gib /)"
if [[ -z "$internal_free" ]]; then
  bad "could not read free space on / (df failed)"
elif (( internal_free < MIN_INTERNAL_FREE_GB )); then
  bad "internal free ${internal_free} GiB < required ${MIN_INTERNAL_FREE_GB} GiB (swap can't grow safely — free disk before running)"
else
  ok "internal free ${internal_free} GiB (>= ${MIN_INTERNAL_FREE_GB} GiB)"
fi

# 2) Assets (model/venv) volume: read the configured root, confirm mount, check headroom.
if [[ "$SKIP_ASSETS_CHECK" == "1" ]]; then
  note "assets-volume check skipped (COMPAT_SKIP_ASSETS_CHECK=1)"
else
  assets_root=""
  if [[ -f "$STORAGE_JSON" ]]; then
    assets_root="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("assetsRoot",""))' "$STORAGE_JSON" 2>/dev/null || true)"
  fi
  if [[ -z "$assets_root" ]]; then
    note "no assetsRoot configured in $STORAGE_JSON — treating runtime as internal-only"
  elif [[ ! -d "$assets_root" ]]; then
    bad "assets volume not mounted: $assets_root is missing (reconnect the external SSD)"
  else
    assets_free="$(free_gib "$assets_root")"
    if [[ -z "$assets_free" ]]; then
      bad "could not read free space on assets volume $assets_root"
    elif (( assets_free < MIN_ASSETS_FREE_GB )); then
      bad "assets volume free ${assets_free} GiB < required ${MIN_ASSETS_FREE_GB} GiB ($assets_root)"
    else
      ok "assets volume mounted, free ${assets_free} GiB (>= ${MIN_ASSETS_FREE_GB} GiB): $assets_root"
    fi
  fi
fi

# 3) System memory pressure (best-effort; skipped if the tool isn't available).
mem_free_pct="$(memory_pressure 2>/dev/null | awk -F': ' '/System-wide memory free percentage/{gsub(/%/,"",$2);print int($2)}')"
if [[ -z "$mem_free_pct" ]]; then
  note "memory pressure unavailable — skipped"
elif (( mem_free_pct < MIN_MEM_FREE_PCT )); then
  bad "system free memory ${mem_free_pct}% < ${MIN_MEM_FREE_PCT}% (let memory settle before running)"
else
  ok "system free memory ${mem_free_pct}% (>= ${MIN_MEM_FREE_PCT}%)"
fi

# 4) Swap usage context (informational — the disk-headroom gate above is the real protection).
swap_line="$(sysctl -n vm.swapusage 2>/dev/null || true)"
[[ -n "$swap_line" ]] && note "swap: $swap_line"

if (( fail )); then
  echo "== preflight FAILED — not launching the heavy run =="
  exit 1
fi
echo "== preflight OK =="

# No command to run — this was a check-only invocation.
(( $# == 0 )) && exit 0

# Cap thread oversubscription and MPS memory watermark for the child, unless already set by the caller.
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-4}"
export VECLIB_MAXIMUM_THREADS="${VECLIB_MAXIMUM_THREADS:-4}"
export TOKENIZERS_PARALLELISM="${TOKENIZERS_PARALLELISM:-false}"
export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"
# Cap MPS allocations so torch reclaims earlier instead of driving the machine into swap.
export PYTORCH_MPS_HIGH_WATERMARK_RATIO="${PYTORCH_MPS_HIGH_WATERMARK_RATIO:-0.7}"

echo "== launching (thread caps + MPS watermark applied): $* =="
exec "$@"
