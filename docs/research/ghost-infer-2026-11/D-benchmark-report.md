# Benchmark report: esh baseline vs Ghost-Infer-derived changes (2026-11-14)

All numbers are **measured** on this machine through esh's production inference paths. No number is borrowed from
Ghost Infer's docs. Raw records (one JSON line per run, with full outputs where `--keep-text` was used):
`benchmarks/results/ghost-infer-study.jsonl`. Tables: `python benchmarks/summarize_bench.py --labels <label…>`.

## Setup

| | |
|---|---|
| Machine | Apple M1 Pro, 32 GB unified memory, macOS 27.0 (26A428); internal disk 3–5 GB free during the study |
| MLX | mlx 0.32.2, mlx-lm 0.31.3, Python 3.11 (esh managed venv `~/.esh/runtime/py311`) |
| llama.cpp | `llama-server` 8660 (`d00685831`), Homebrew; same tag as esh's `scripts/build-llama.sh` |
| Path under test | MLX: the bridge's persistent **`mlx-serve`** worker (what `MLXPersistentRuntime` runs). GGUF: `llama-server` with **esh's exact arguments** (`-c 8192 -ngl 999 --jinja --reasoning-format none --no-webui -np 1`) |
| Guard | A port of `MemorySafetyPreflight.evaluate` before every load, plus a 0.5 s watchdog that kills the engine on critical pressure or <2 GB available |
| Sampling | Greedy (temperature 0); thinking off (`enable_thinking=false`); outputs compared byte-for-byte with SHA-256 |
| Runs | One warm-up (discarded), then 3 measured runs per (model, variant, workload) unless noted; medians reported |

**Workloads** (`benchmarks/esh_infer_bench.py`, fixtures in `benchmarks/fixtures/`):

| Workload | What it is | Scored for |
|---|---|---|
| `chat` | A 3-sentence explanation | — |
| `code-edit` | Rename a type in a ~140-line Swift file and return the **whole file** (≈1.3K output tokens) | rename completeness, length ratio |
| `tool-json` | Emit an `apply_patch` tool call whose `old` text is copied from context | JSON validity, schema, `old` verbatim |
| `multi-turn` | 4 short refactoring turns | — |
| `agent-session` | Ashex-shaped: ~1.6K-token context (file + failing test), then 3 short follow-ups | — |
| `ctx-Nk` | Long-context QA at 1K / 8K / 32K prompt tokens | answer relevance |

**Metric notes**
- Time to first token (TTFT) and end-to-end time are measured client-side, so they include everything esh's worker does, including state-file load and save.
- "Decode" is client-side: (generated − 1) / (done − first token). For the legacy MLX prefix path it therefore *includes* the post-generation KV-snapshot write. That is intentional, because the user waits for it, but it makes legacy decode look low at long context.
- For GGUF, repeated identical prompts hit llama-server's own prompt cache, so GGUF TTFT/prefill figures are not meaningful; compare decode and end-to-end time.

## Models

| Model | Format | Type | Size | Notes |
|---|---|---|---|---|
| Qwen3-0.6B 8-bit (esh install) | MLX | dense, small | 0.6 GB | 32K context |
| Meta-Llama-3-8B-Instruct 4-bit | MLX | dense, medium, general | 4.5 GB | 8K context; follows coding instructions |
| Qwen2.5-1.5B-Instruct Q4_K_M (esh install) | GGUF | dense, small | 1.0 GB | |
| Llama-3-8B-Web Q8_0 (esh install) | GGUF | dense, medium | 8.0 GB | web-agent fine-tune; does **not** follow the edit/tool tasks (useful as the "no copying" case) |
| Qwen3-30B-A3B 4-bit (esh install) | MLX | **MoE** 128 experts / 8 active | 16 GB | **gated by the memory preflight on every attempt** (needs ≈21.6 GB; 7–12 GB available, 4.8 GB swap headroom). Not measured; see F-roadmap P1.1 |

## 1. MLX prompt-lookup speculation (`ESH_MLX_LOOKUP_SPEC=1`)

Llama-3-8B-Instruct 4-bit, baseline vs the final controller (`llama3-8b-4bit` vs `llama3-8b-4bit-v2`):

| Workload | Decode tok/s | Δ | End-to-end s | Δ | Acceptance | Output identical to baseline |
|---|---|---|---|---|---|---|
| code-edit (1,308 tok) | 28.0 → **48.4** | **+73%** | 53.7 → **33.9** | **−37%** | 91–93% (1,040–1,080 verified drafts + 110–150 free first-token hits per run) | 3/3 |
| tool-json | 29.1 → 29.4 | +1% | 8.35 → 8.55 | +2% | 66–82% | 2/3 (1 diverged after the complete JSON) |
| chat | 31.7 → 32.0 | +1% | 4.39 → 4.35 | −1% | — | 3/3 |
| multi-turn | 22.8 → 21.4 | −6%* | 29.3 → 28.2 | −4% | — | 3/3 |

\* The multi-turn decode figure is dominated by the legacy snapshot write after each turn (see §3), not by speculation.

- **The first controller** (most-recent match, EMA back-off) gave only +29% on code-edit and −5% on tool-json, so the controller matters.
- **The final controller** adds Ghost-Infer-style longest-match candidates, per-match-length acceptance, an online cost model and a >5% expected-gain gate, plus the free first-token check against the in-flight step.
- **Qwen3-0.6B:** neutral (code edit 75 → 77 tok/s at 75% acceptance). Per-step Python and graph overhead dominate at that size.
- **Correctness:** 14/15 Llama-3-8B outputs are byte-identical to plain greedy. The divergences are floating-point near-ties between MLX's batched (`qmm`) and single-token (`qmv`) kernels; quality scores are identical. A real-MLX unit test checks token-for-token equality and KV length on a tiny model (`Tests/Python/test_lookup_spec.py`).

## 2. GGUF: upstream n-gram speculation and KV type (`ESH_LLAMA_SPEC_TYPE`, `ESH_LLAMA_KV_TYPE`)

**Qwen2.5-1.5B Q4_K_M**, decode tok/s (Δ vs esh's current arguments), with output identity vs baseline:

| Variant | code-edit | tool-json | chat | multi-turn | Notes |
|---|---|---|---|---|---|
| baseline (esh today) | 77.0 | 80.5 | 67.0 | 78.7 | |
| `--spec-type ngram-simple` | **263.4 (+242%)**, e2e −71%, 3/3 | 98.5 (+22%), 0/3 † | 71.1 (+6%), 3/3 | 82.7 (+5%), 3/3 | **recommended** |
| `--spec-type ngram-mod` | 267.6 (+248%), 3/3 | 262.4 (+226%), 3/3 | 146.2 (+118%) ‡, 0/3 | 113.3 (+44%) ‡, 0/3 | keeps n-grams **across requests** |
| `--spec-type ngram-map-k` | 243.6 (+217%), 3/3 | crashed | 82.8 (+24%), 3/3 | — | **llama-server crashed** |
| `-ctk q8_0 -ctv q8_0` | 61.9 (−20%) | 66.1 (−18%) | 73.1 (+9%) | 68.2 (−13%) | KV-memory lever only |

† Diverged at character 890 of 1,137 (a floating-point near-tie); both outputs are valid tool calls with verbatim `old`.
‡ Inflated: `ngram-mod` learned the warm-up run's identical answer within the same server process.

**Llama-3-8B-Web Q8_0**, a model that does not copy context (it answers the edit task in 118 tokens):

| | code-edit | tool-json | chat |
|---|---|---|---|
| baseline | 16.0 | 14.2 | 16.8 |
| `ngram-simple` | 13.9 (**−13%**) | 16.5 (+16%) | 17.4 (+4%) |

Outputs were identical 3/3 in every column. This is why speculation stays opt-in and should be gated on the coding/agent intent.

## 3. MLX prefix reuse (`ESH_MLX_PREFIX_CACHE=tokens|live`)

**Llama-3-8B-Instruct 4-bit, `agent-session`** (median over 3 runs, per turn):

| Mode | TTFT per turn (s) | End-to-end per turn (s) | Tokens prefilled per turn | Session end-to-end | Peak Metal |
|---|---|---|---|---|---|
| legacy (default) | 6.98 / 7.91 / 7.98 / 8.36 | 11.2 / 12.0 / 11.9 / 12.7 | 1612 / 1669 / 1694 / 1749 | 47.8 s | 6.29 GB |
| `tokens` | 6.86 / 1.15 / 1.41 / 1.65 | 8.9 / 2.5 / 3.5 / 3.9 | 1612 / **27 / 21 / 42** | 19.2 s (**−60%**) | 6.29 GB |
| `live` | 6.83 / **0.39 / 0.43 / 0.60** | 7.6 / 0.4 / 1.0 / 1.2 | 1612 / 27 / 21 / 42 | **10.2 s (−79%)** | 6.53 GB (+0.24) |
| `live` + lookup | 6.88 / 0.38 / 0.48 / 0.63 | 7.7 / 0.4 / 1.1 / 1.3 | same | 10.5 s (−78%) | 6.53 GB |

- **`multi-turn`** session end-to-end: legacy 25.8 s → `tokens` 18.4 s (−29%) → `live` 16.5 s (−36%); last-turn TTFT 3.23 → 0.61 → 0.36 s.
- **Hits:** legacy 0/12 turns, both new modes 9/12 (every follow-up turn).
- **Outputs:** identical to legacy, 3/3, in `tokens` and `live`.

**Long context, Qwen3-0.6B 8-bit** (single turn; shows the snapshot tax):

| Context | legacy | `tokens` | `live` | legacy + disk guard |
|---|---|---|---|---|
| 1K | 2.75 s e2e | 3.26 s § | **0.82 s** | — |
| 8K | 28.8 s e2e, later **ENOSPC** | 17.1 s, later **ENOSPC** | **5.46 s** | **5.22 s** (snapshot skipped) |
| 32K | **killed: memory pressure critical** | **killed: memory pressure critical** | **48.1 s** (prefill 584 tok/s, decode 28.4 tok/s) | — |

§ Ran right after the 32K run had been killed and the system was swapping; it is not a fair comparison.

The legacy state file serializes the whole KV cache twice (base64 tensors + base64 safetensors) into the temp
directory on the **internal** disk every turn. At 8K that took the free disk to zero; at 32K it drove memory
pressure critical; and a worker killed mid-save leaked a 3.1 GB staging file. Commit `4c6813c` adds a disk-budget
guard for every mode, so the snapshot is skipped and the request succeeds. The `live` mode avoids the problem
entirely.

## 4. Regressions and costs

- **Lookup speculation:**
  - neutral (±1–6%) on chat, tool-JSON and multi-turn with the final controller;
  - outputs can differ at floating-point near-ties, and because the controller is timing-adaptive the divergence point is **not reproducible run to run**;
  - temperature > 0 is not covered (it falls back to the normal path).
- **GGUF `ngram-simple`:** −13% when the model doesn't copy context.
- **q8_0 KV on llama.cpp/Metal:** −13…−20% decode at short context.
- **`live` prefix mode:** keeps one session's KV resident (+0.24 GB at about 1.7K context; about 128 KB per token at 8B). In this mode `esh cache export` from another process sees no tensors.
- **`tokens` mode:** still writes a snapshot (once, not twice); the disk guard applies.

## 5. What was not measured, and why

- **MoE (Qwen3-30B-A3B):** blocked by the memory preflight (by design). The command is in F-roadmap P1.1.
- **A dedicated coding model:** none installed in MLX besides the general Llama-3-8B; deepseek-coder-7b (13 GB bf16) would be gated.
- **Concurrent requests:** a single engine per run here. `RuntimeLifecycleManager` concurrency is on the roadmap.
- **Cold start vs warm:** worker load times are in the records (`loadWallS`: Llama-3-8B 8–18 s cold from the SSD, Qwen3-0.6B 4–7 s), but no dedicated cold-start optimization was attempted. Ghost Infer's techniques here (pinned staging, NVRTC kernel cache) are CUDA-specific.
