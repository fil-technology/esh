#!/usr/bin/env bash
# Phase-C: Qwen3-Next-80B-A3B @ IQ2_XS (22.2 GB GGUF) via llama.cpp Metal on M1 Pro 32 GB — the "80B-class brain
# resident, no streaming" bet. Downloads to the SSD GGUF cache, runs one single-turn chat with the model's own
# template, and captures gen tok/s + prompt tok/s + max RSS + swap(pageout) delta (the swap-safety check).
set -uo pipefail
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
export LLAMA_CACHE="/Volumes/Sviat SSD/esh-models/caches/llm-gguf"
mkdir -p "$LLAMA_CACHE"
LLAMA="/opt/homebrew/bin/llama-cli"
REPO="bartowski/Qwen_Qwen3-Next-80B-A3B-Instruct-GGUF:IQ2_XS"
PROMPT="Write a Swift function that debounces an async throwing operation, and explain the concurrency model in 3 sentences."

# Memory guard (brief §19): need headroom so a ~22 GB model doesn't drive the nearly-full internal swap volume.
FREEGB=$(vm_stat | awk '/Pages free/{f=$3}/Pages speculative/{s=$3}/Pages inactive/{i=$3}END{gsub(/\./,"",f);gsub(/\./,"",s);gsub(/\./,"",i);printf "%.1f",(f+s+i)*16384/1e9}')
echo "free_before_gb=$FREEGB"
awk "BEGIN{exit !($FREEGB < 10)}" && { echo "ABORT: <10 GB free"; exit 3; }

PO_BEFORE=$(vm_stat | awk '/Pageouts/{gsub(/\./,"",$NF);print $NF}')
echo "pageouts_before=$PO_BEFORE  start=$(date +%H:%M:%S)"

# -st single-turn (applies chat template, one response, exits); -fa auto Flash Attention; -ngl 99 all layers on
# Metal (unified memory); modest context to keep KV small. /usr/bin/time -l reports max RSS.
/usr/bin/time -l "$LLAMA" \
  -hf "$REPO" -ngl 99 -c 4096 -n 160 -fa auto -st -s 42 --no-warmup \
  -p "$PROMPT" > "$BENCH_DIR/qwen3next_iq2xs.out" 2> "$BENCH_DIR/qwen3next_iq2xs.err"
RC=$?

PO_AFTER=$(vm_stat | awk '/Pageouts/{gsub(/\./,"",$NF);print $NF}')
echo "rc=$RC pageouts_after=$PO_AFTER end=$(date +%H:%M:%S)"
echo "=== perf ===" ; grep -iE "llama_perf|eval time|tokens per second|load time|model size|^load_tensors|using .* buffer" "$BENCH_DIR/qwen3next_iq2xs.err" | tail -25
echo "=== max RSS / mem ===" ; grep -iE "maximum resident set size|peak memory footprint" "$BENCH_DIR/qwen3next_iq2xs.err" | tail -5
echo "=== swap delta (pageouts) ===" ; echo "$((PO_AFTER - PO_BEFORE)) pages (*16KB)"
echo "=== answer (first 800 chars) ===" ; head -c 800 "$BENCH_DIR/qwen3next_iq2xs.out"
