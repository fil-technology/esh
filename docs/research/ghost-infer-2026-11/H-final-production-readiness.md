# Final production readiness (2026-11-14)

This follows [G-production-hardening-report.md](G-production-hardening-report.md).

**Approved and applied:**
- The validated safety, correctness, lifecycle, metrics and performance fixes are approved to merge.
- `ESH_MLX_PREFIX_CACHE=tokens` stays the default.
- Speculative decoding stays opt-in.

**Not applied:**
- `live` is **not** the default. §6 proposes it only for persistent MLX workers, and that needs your approval.

## 1. Merge status and commit references

| PR | Head | Base | CI |
|---|---|---|---|
| fil-technology/esh#23 (speech fixes + validated catalog) | `a41310f` | `main` | Live speech smoke ✅, iOS ✅, package smoke ✅, **Test and Verify ❌** |
| fil-technology/esh#24 (Ghost Infer study + opt-in speedups) | `ea4c486` | #23 | Same as #23 |
| fil-technology/esh#25 (hardening + KV-growth guard + validation) | `7f249fe` | #24 | Running |
| fil-technology/esh#26 (CI hang fix, separate session) | — | `main` | Running |

**Nothing is merged yet.** You asked for successful CI on every merge without bypassing tests. "Test and Verify" fails on #23/#24 only because of a **pre-existing hang on `main`**: `main`'s own last three runs timed out at 45 minutes with about 500 tests started and none finished.

The order once #26 is green and merged:
1. Bring `main` into #23, wait for green CI, merge.
2. Retarget #24 to `main`, wait for green, merge.
3. Same for #25.
4. Verify the merged `main` builds and passes its tests.

## 2. Tests (final head `7f249fe`)

| Suite | Result |
|---|---|
| Root Swift package | **pass**: 553 tests in the main run, plus 102 / 73 / 43 / 8 / 4 in the other targets. New suites: load gate (5), pool caches / pressure / shutdown / context growth (17), KV estimator (5), GGUF timings (3), prepare skip (2), state files (3) |
| macOS package (also compiles every macOS-side change) | **pass**: 191 + 20 |
| Python, including real-MLX equivalence tests on tiny models | **pass** (50) |
| Bridge: copies identical, no undefined names | **pass** |
| Real-model prefix-cache validation (`validate_prefix_cache.py`) | Llama-3-8B 19/19 · Mistral-7B `tokens`/`live` all pass, **legacy duplicates KV** · Qwen3-0.6B: diagnosed bf16 near-ties only |
| KV-growth guard on a real model (`validate_kv_guard.py`, Qwen3-0.6B) | all pass |
| `esh serve` live validation (`serve_live_validation.py`, Llama-3-8B + Qwen2.5-1.5B GGUF) | all pass (§4) |

## 3. KV-growth safety (`ac13124`)

The gap was that the load gate judged model weights, but nothing judged a long context growing the KV cache of a model that was already loaded. Both layers below extend existing components: there is no new subsystem.

1. **Pool layer, before generation** (`RuntimeLifecycleManager.ensureHeadroom`, called by `ExternalInferenceService` for MLX):
   - **Estimate:** `KVCacheEstimator` reads `config.json` (layers × KV heads × head dim × 4 bytes per token) and counts the whole prompt plus every allowed new token. This is conservative.
   - **Judge:** `MemorySafetyPreflight` in growth mode, which drops the small-model floor and uses the same swap-headroom rule.
   - **If it doesn't fit:** release **idle** residents' caches, then evict **idle** models least-recently-used first, waiting for each unload, and re-judge after every step. **Active requests are never touched.**
   - **If it still doesn't fit:** `insufficientMemoryForContext`, saying how much is needed and what to do.
   - **Without a pool (one-shot):** the model isn't loaded yet, so weights and growth are judged together.
   - **GGUF:** bounded at load by llama-server's `-c`.
2. **Worker layer, with exact token counts** (bridge):
   - **Before prefill:** re-checks with the real number of new tokens and the model's real KV dimensions, drops its own idle session caches if that's enough, and otherwise refuses with an actionable error.
   - **During generation:** checks pressure every 256 tokens. On critical pressure it releases idle caches; if that doesn't relieve it, it stops cleanly with `finishReason: "memory_pressure"`, keeping the partial output.
   - **Metrics:** `kvGrowthBytes`, `kvBytesPerToken` and `kvGuardFreedBytes`.

**Verified:**
- 9 Swift unit tests covering all four outcomes: fits, fits after releasing caches, fits after evicting an idle model, refused without touching active work.
- On a real model: bytes per token equal the config; a real refusal; caches dropped before refusing; a clean pressure stop.
- Through the real binary: `esh infer` and `esh serve` return "Not enough memory to run this request on … its context needs ~N GB more KV cache (…) Shorten the conversation or max_tokens…". The pool stays consistent and the next request succeeds.

## 4. Real Ashex results

**Ashex → esh agent runs (`ashex exec --provider esh`, Ashex 0.2.30, real tasks on a copy of the fixture project):**
- **No run completed, in either prefix mode.**
  - Every `esh infer` call succeeds: exit 0, 12–35 s per step.
  - But Llama-3-8B (and Qwen3-0.6B) reply in YAML-like pseudo-JSON (`tool_name: filesystem / arguments: {…}`), not the strict JSON action format Ashex parses, so Ashex discards each turn.
  - Ashex sends no `responseFormat`, and esh's MLX backend has no constrained decoding. This is a **pre-existing integration gap, independent of this work**.
  - Qwen3-30B-A3B, which could likely hold the format, was refused by the memory guard (needs about 23 GB).
- **Replay of a captured real Ashex request** (6 messages, 14K characters, temperature forced to 0, interleaved, 3 runs each):
  - legacy 28.3 s vs `tokens` 28.8 s, **identical output**. No regression from the `tokens` default.
  - Ashex's own temperature of 0.7 makes timing comparisons noisy; the first pass suggested a 20% gap that disappeared at temperature 0.
- **Cost of the one-shot path:** each Ashex step re-prefills the whole conversation (about 18 s time to first token here), because processes can't share a cache.
- **Ashex can't drive `esh serve` for agent runs today:**
  - its `dflash` provider (OpenAI chat completions) is direct-chat only;
  - `openai` is hard-coded to api.openai.com;
  - this release has no `deepseek` provider;
  - `esh serve` has no Ollama `/api/chat`.

**Ashex-shaped sessions through the real `esh serve`** (Llama-3-8B-Instruct 4-bit MLX + Qwen2.5-1.5B GGUF; `benchmarks/serve_live_validation.py`):

| Measurement | Legacy | `tokens` (default) | `live` |
|---|---|---|---|
| 10-turn agent session (1.6K-token fixed context + follow-ups) | 123.0 s | **33.2 s (−73%)** | **26.9 s (−78%)** |
| Follow-up time to first token | 8–10 s | 0.52–0.80 s | 0.47–0.73 s |
| Follow-up end-to-end | 9–14 s | 1.0–2.5 s | 0.5–1.8 s |
| 3 concurrent conversations (4 turns each) | 70.6 s | 54.0 s | 50.8 s |
| Output identical to legacy | — | **17/17 turns** | **17/17 turns** |
| Concurrent output equals serial | ✅ | ✅ | ✅ |
| MLX ↔ GGUF switching (both stay resident, continuation correct) | ✅ | ✅ | ✅ |
| Server peak RSS | 8.67 GB | 7.30 GB | 7.25 GB (+0.22 GB resident session cache) |
| Orphaned processes after stop | none | none | none |

`live`-only checks:
- **Tiny budget** (`ESH_MLX_LIVE_PREFIX_MAX_BYTES=1 MB`): not retained, output still identical.
- **SIGTERM and restart mid-conversation:** the continued turn is identical to legacy, no orphans, and only the running server's own state file remains.

Earlier, on Qwen3-0.6B through `esh serve` (see G): `live` cut the agent session by 63% and concurrent work by 80%, with peak RSS 4.95 → 1.25 GB.

## 5. Memory-pressure behavior

- **Load:** every load path is gated live (load gate).
- **Context growth:** gated before generation (pool) and again before prefill (worker).
- **During generation:** critical pressure stops growth cleanly.
- **Resident caches:**
  - **budgeted:** they count in the pool budget (`/v1/runtime` `residentCacheGB`) and are capped at min(25% of RAM, 8 GiB) with 2 slots;
  - **not retained** under critical pressure;
  - **released on demand:** first on a pool shortfall, and on system warnings (`esh serve` subscribes to memory pressure); critical also evicts idle models.
- **Disk:** snapshots never breach the 3 GB swap floor, and crash leftovers are swept.
- **Not exercised:** a real system-wide pressure event. `memory_pressure -S` changes the level for every app, so it wasn't used; the path is covered by unit tests with injected events.

## 6. Recommended production defaults

| Setting | State | Recommendation |
|---|---|---|
| `ESH_MLX_PREFIX_CACHE=tokens` | **default (applied)** | Keep. It's the fallback for one-shot execution. |
| `live` for **persistent MLX workers** (`esh serve` with `ESH_MLX_PERSISTENT=1`) | opt-in | **Proposed for approval.** Fastest of the three, and correct in every scenario above. Memory is accounted, capped, released under pressure and on shutdown, and guarded against growth. Its cost is the resident cache (0.2–0.25 GB per session at about 1.7K tokens; capped). |
| Load gate, KV-growth guard, temp-file safety, disk guard, one-shot double-load fix, awaited shutdown, metrics, bug fixes | default (applied) | Merge. |
| MLX lookup speculation / GGUF `ngram-simple` | opt-in | Keep opt-in (§7). |
| Exact lookup, `ngram-mod`/`ngram-map-k`, q8_0 KV | experimental | Don't recommend. |

## 7. Speculative decoding: kept opt-in; future Router integration

- **Measured:** +62% to +90% decode on copy-heavy edits (MLX 7–8B), and up to +359% with GGUF `ngram-simple`. −7% to +3% elsewhere, and −13% when the model doesn't copy its input.
- **Not bit-exact on MLX:** forwards are batch-invariant only for ≤ 4–5 tokens at short context and ≤ 2 at 8K and beyond. Exact mode loses the speedup.
- The adaptive controller is unchanged.
- **Router integration** (future, evidence-driven): enable per request only when **all** of these hold:
  - the intent is `code`/`agentrun` and the output is expected to copy context (edits, refactors, patch generation);
  - sampling is greedy;
  - the caller doesn't need byte-reproducible output (a `deterministic` request flag would force it off);
  - recent measured acceptance for that model is high (the controller already tracks it).

  Feed `draftTokens`/`draftAcceptedTokens` from `Metrics` into the scheduler's evidence store so the decision is data-driven, and keep it off for MoE until it has been measured.

## 8. Remaining limitations

1. **Merges are waiting on the CI hang fix (#26).** Nothing is merged yet.
2. **Ashex agent runs on esh + MLX don't complete:** the model output format isn't valid JSON, and there's no constrained decoding on MLX. It needs either a capable model that fits (Qwen3-30B was refused by the guard) or structured output from Ashex/esh (a `responseFormat` request; JSON-schema-constrained decoding on MLX).
3. **Ashex can't use `esh serve` for agent runs** with its current providers. Adding an OpenAI-compatible tool-capable provider (or a configurable base URL for `openai`) would give Ashex the 73–78% session gains.
4. **The Qwen3-30B-A3B MoE was never measured**: the memory guard refused it every time.
5. **Real system memory pressure** hasn't been exercised (simulation would affect every app).
6. **The KV-growth estimate is conservative**: it counts the whole prompt even when most of it will be reused. On a machine already close to its limit it could refuse a long session that would actually fit thanks to the cache. The worker's exact check is the second line of defense.
7. **Speculation is not bit-exact** (§7).
