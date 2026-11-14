# esh coding benchmark harness

Reproducible, objective-grader coding benchmark for local models on esh (Apple Silicon). Sibling of
`benchmarks/quality/` — same philosophy (executable tests, temperature 0, no LLM-as-judge), focused on the
dimensions in the 2026-10 research brief: **Swift / SwiftUI, concurrency, TypeScript, multi-file editing,
tool calling, structured output, agent recovery.**

## Files
- `suite_coding.py` — task packs + objective graders. 10 tasks across 7 categories.
- `run_coding_mlx.py` — runner. Drives the **same engine esh's text backend uses** (the `mlx_lm` worker) and
  applies **esh's memory-safety rule** (a faithful port of `Sources/EshCore/Runtime/MemorySafetyPreflight.swift`:
  `smallModelFloorGB=4.0`, `swapDiskFloorGB=3.0`) *before* loading weights, so a run respects the same guard as
  the live `esh` path. Emits a JSON report with per-task pass/fail, TTFT, decode tok/s, overall peak memory,
  swap before/after, and tool-call reliability.
- `validate_graders.py` — validates every grader against the **real toolchains** with golden correct/incorrect
  solutions (no model, no gate). Proves each grader compiles+runs code and discriminates pass from fail.
- `grader-validation.json` — last validation result (10/10 graders discriminate).
- `baseline-30b-gate.json` — a captured esh memory-gate decision for the installed 30B on this machine.

## Graders / toolchains
- **Swift** (`swiftc -O`, Apple Swift 6.x): compile + run a single-file program with top-level `await`; tests use
  `precondition`. Covers compiler-error fixing, implementation, and actor concurrency (1000-task race check).
- **TypeScript** (`node` ≥ 23, native type-stripping — no `tsc`/npm download needed): write `.ts`, execute with
  assertions. Covers implementation, bug-fixing, and a two-file edit (value-based cross-file imports so node can
  run them; type-only cross-file imports are intentionally avoided).
- **Structured output / tool calling** (JSON): schema + value checks; tool-call name/arguments validation.
- **Agent recovery** (two-turn): turn 1 must be a valid tool call; we inject a tool **error** result, then grade
  whether turn 2 **recovers** with a corrected call.

## Run

Validate the graders (fast, no model):
```bash
ESH_CODING_PYEXE="$HOME/.esh/runtime/python/bin/python3" \
  "$HOME/.esh/runtime/python/bin/python3" validate_graders.py grader-validation.json
```

Run against a model through the esh memory-safe gate (uses the esh worker Python with `mlx_lm`):
```bash
# <repo-or-local-path>  <out.json>  [required_peak_gb]
"$HOME/.esh/runtime/python/bin/python3" run_coding_mlx.py \
  mlx-community/Qwen3-30B-A3B-4bit results-30b.json 17.3
```
If the memory gate REFUSES (insufficient internal-disk/swap headroom), the runner writes a `GATED` report and
loads **no** weights. Free internal disk (e.g. install the pending macOS update to reclaim staged-update space,
or clear regenerable caches) until `system_volume_free_gb ≥ ~3 GB + any RAM deficit`, then re-run. `ESH_FORCE=1`
overrides the gate (not recommended).

## Baseline (installed Qwen3-30B-A3B-4bit, this machine)
The 30B is esh's `--best` default and the apples-to-apples baseline. Measured via esh's existing harness
(`benchmarks/quality/results_30b.json`, `benchmarks/model-results.json`, M1 Pro / 32 GB, 2026-10):
- Quality suite: **9/9** (coding 3/3, reasoning 2/2, structured 1/1, instruction 1/1, tool_calling 1/1,
  long_context 1/1), peak **18.1 GB**.
- Perf: **28.65 gen tok/s** (160-token gen), decode ~31–42 tok/s on the suite, peak **17.3 GB**, swap-safe.

A fresh run of *this* coding suite against the 30B requires the memory gate to pass; see `baseline-30b-gate.json`
for the current decision on this machine.
