# Phase-C quality comparison — MEASURED (2026-10-12)

Reproducible, objective quality suite (brief §15) comparing the two resident candidates on the M1 Pro / 32 GB.
Temperature 0 (greedy) for determinism. Both models run the **same** 9 tasks with **objective** scorers:
executable unit tests for code, schema validation for JSON, exact-match for reasoning + needle retrieval,
regex for instruction-following, and a tool-call shape check. Scorers strip `<think>` blocks; the 30B is run in
**non-thinking mode** to match the Instruct 80B (fair like-for-like). Harness: `suite.py` + `run_mlx.py`
(MLX) / `run_80b.sh` + `run_http.py` (llama-server). Raw results: `results_30b.json`, `results_80b.json`.

## Results

| Task (category) | 30B 4-bit (MLX) | 80B IQ2_XS (llama.cpp) |
|---|---|---|
| two_sum (coding, exec) | ✅ | ✅ |
| roman_to_int (coding, exec) | ✅ | ✅ |
| Debouncer (coding, exec) | ✅ | ✅ |
| tank fill (reasoning) | ✅ | ✅ |
| house logic (reasoning) | ✅ | ✅ |
| JSON extract (structured) | ✅ | ✅ |
| 3-bullets (instruction) | ✅ | ✅ |
| get_weather (tool call) | ✅ | ✅ |
| Rotterdam code (long-context needle) | ✅ | ✅ |
| **TOTAL** | **9 / 9** | **9 / 9** |
| Speed (per task) | **~40 tok/s** | ~11–18 tok/s (needle prefill 2.7) |
| Peak memory | 18.1 GB | 21.2 GB |
| Swap-safe | anytime | post-reboot only |

## Verdict (evidence-labelled)

- **MEASURED:** both models pass 100% of the objective suite. **This suite does not discriminate quality** —
  the tasks are within reach of both. The real, measured difference is **speed (30B ~2–3× faster) and safety
  (30B needs no reboot headroom).**
- **IMPORTANT (anti-overfit):** an earlier *single* 80B sample (a Swift async debounce) was subtly buggy, which
  could have been mistaken for IQ2 degradation. The objective suite (brief: "do not infer degradation from a
  single failed response") shows the 80B passing the equivalent Python debounce — so that single sample was not
  representative. Conversely, these tasks are too easy to prove the 80B's *advantage* either.
- **NOT shown:** where IQ2 actually hurts, or where 80B capacity actually helps — both would require a harder,
  discriminating task set (longer code, multi-step reasoning, larger context). Follow-up if `--best` needs to
  distinguish them beyond speed.

## `esh run --best` recommendation (measured utility, not parameter count)

- **Default / `--best`, `--best coding`: Qwen3-30B-A3B (MLX 4-bit).** Equal objective quality, ~2–3× faster,
  fits 18 GB and is swap-safe with no special machine state. On this machine the smaller model is the better
  *useful* default.
- **`--best --max-quality` (opt-in): Qwen3-Next-80B-A3B (llama.cpp IQ2_XS).** Reach for it only when a task may
  exceed the 30B's capacity and the user accepts ~half the speed + the post-reboot memory headroom requirement.
  Not a silent default (IQ2 is lossy; verify correctness-sensitive output).
