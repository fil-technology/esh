#!/usr/bin/env bash
# Start llama-server once with the 80B IQ2_XS, run the quality suite over HTTP, then shut down.
# Memory watchdog + hard time cap; server holds ~21 GB resident so this needs post-reboot headroom.
set -uo pipefail
Q="$(cd "$(dirname "$0")" && pwd)"
GGUF="/Volumes/Sviat SSD/esh-models/caches/llm-gguf/models--bartowski--Qwen_Qwen3-Next-80B-A3B-Instruct-GGUF/snapshots/c07b9268d97d8ba09d0529980627f3bd70f5f90a/Qwen_Qwen3-Next-80B-A3B-Instruct-IQ2_XS.gguf"
PORT=8099; URL="http://127.0.0.1:$PORT"; PY="$HOME/.esh/runtime/py311/venv/bin/python3"
MON="$Q/q80b.mon"; : > "$MON"
freegb(){ vm_stat|awk '/Pages free/{f=$3}/Pages speculative/{s=$3}/Pages inactive/{i=$3}END{gsub(/\./,"",f);gsub(/\./,"",s);gsub(/\./,"",i);printf "%.1f",(f+s+i)*16384/1e9}'; }
swapgb(){ sysctl -n vm.swapusage|awk '{for(i=1;i<=NF;i++)if($i=="used"){gsub(/M/,"",$(i+2));printf "%.1f",$(i+2)/1024}}'; }
intfreegb(){ df -g /|awk 'NR==2{print $4}'; }

echo "precheck ram=$(freegb) swap=$(swapgb) int=$(intfreegb)"
awk "BEGIN{exit !($(freegb)<8 || $(intfreegb)<8)}" && { echo "ABORT precheck (need >=8GB RAM & >=8GB internal)"; exit 3; }

/opt/homebrew/bin/llama-server -m "$GGUF" -ngl 99 -c 8192 -fa auto --jinja --port $PORT --host 127.0.0.1 -np 1 \
  > "$Q/server.out" 2> "$Q/server.err" &
SRV=$!
echo "server pid=$SRV start $(date +%H:%M:%S)"

# Watchdog.
( while kill -0 "$SRV" 2>/dev/null; do
    echo "$(date +%H:%M:%S) ram=$(freegb) swap=$(swapgb) int=$(intfreegb)" >> "$MON"
    if awk "BEGIN{exit !($(intfreegb)<2 || $(swapgb)>12 || $(freegb)<1.0)}"; then echo "WATCHDOG ABORT" >>"$MON"; kill -9 "$SRV"; break; fi
    sleep 3
  done ) & WD=$!

# Wait for health (model load ~40-60s cold), max 180s.
ok=0
for i in $(seq 1 60); do
  if curl -fsS "$URL/health" 2>/dev/null | grep -q '"status":"ok"'; then ok=1; break; fi
  kill -0 "$SRV" 2>/dev/null || { echo "server died during load"; break; }
  sleep 3
done
if [ "$ok" = 1 ]; then
  echo "server healthy $(date +%H:%M:%S); running suite"
  ESH_QUALITY_PYEXE="$PY" ESH_SUITE=suite_hard "$PY" "$Q/run_http.py" "$URL" "$Q/results_hard_80b.json" "Qwen3-Next-80B-A3B-IQ2_XS"
else
  echo "ERROR: server did not become healthy"; tail -5 "$Q/server.err"
fi

kill "$SRV" 2>/dev/null; kill "$WD" 2>/dev/null; wait 2>/dev/null
echo "=== mon tail ===" ; tail -4 "$MON"
echo "done $(date +%H:%M:%S)"
