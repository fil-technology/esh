# Follow-up roadmap (prioritized)

Ordered by measured or expected benefit ÷ engineering risk. Each item says what evidence it needs before a
production default changes.

## P0: promote what was measured here (small, high value)

1. ~~**Make `ESH_MLX_PREFIX_CACHE=tokens` the default.**~~ **Done (2026-11-14, approved).** It was validated on 3 models and templates (G report §4). Rollback: `ESH_MLX_PREFIX_CACHE=legacy`.
   - Why: it fixes two defects in the default path (prefix reuse never hits on Llama-3/Qwen3; untrimmed replay can duplicate tokens). Measured −60% session end-to-end on an Ashex-shaped session, with identical outputs.
   - Evidence still needed: a soak in `esh serve` (`ESH_MLX_PERSISTENT=1`) with real Ashex sessions on Qwen3-30B-A3B and Qwen3-Coder; a check that `esh cache export` / TurboQuant compression still works on `tokens` snapshots (export rebuilds the tensor list; tested only by code path).
2. **Use `live` mode by default when the MLX worker is persistent.** It brought follow-up turns to 0.4–0.6 s time to first token.
   - Cost: one session's KV stays resident (about 128 KB per token at 8B; about 98 KB per token for Qwen3-30B-A3B, i.e. ≈3 GB at 32K).
   - Needs: integration with `RuntimeLifecycleManager` memory accounting (report the resident KV so the pool budget includes it), and dropping the live cache under `reclaimForPressure`.
3. **Intent-gated speculation.** Turn on MLX lookup speculation and GGUF `ngram-simple` only for the `code` / `agentrun` intents, through the existing `auto` resolution; keep it off for chat.
   - Needs: the MoE measurement (P1.1) and a wider coding-task set (e.g. the docs/research coding harness) for quality parity.
4. **Move the MLX state file off the temp dir** (or into the assets volume). The disk guard (`4c6813c`) prevents ENOSPC, but snapshots are still pointless I/O in the persistent worker. `live` mode is the real fix there, and `tokens` remains for one-shot runtimes.
5. **Build and test the macOS package** with the `LlamaServerTuning` wiring (not compiled here because the internal disk was full). Free at least 8 GB internal so the live speech smoke can also run end to end.

## P1: measurements this session could not take

1. **MoE (Qwen3-30B-A3B 4-bit, 16 GB).** The memory preflight gated it on every attempt: about 7–12 GB available against a ≈21.6 GB projected peak, with 4.8 GB internal disk for swap. Re-run after freeing memory:
   ```
   ~/.esh/runtime/py311/venv/bin/python benchmarks/esh_infer_bench.py mlx \
     --model "/Volumes/Sviat SSD/esh-models/models/installs/qwen3-30b-a3b-4bit" --label qwen3-30b-a3b \
     --variant baseline: --variant lookup:ESH_MLX_LOOKUP_SPEC=1 --variant live:ESH_MLX_PREFIX_CACHE=live \
     --workloads chat code-edit tool-json agent-session
   ```
   - Expectation: lookup speculation helps less on MoE than on dense models. Verifying k tokens reads the union of their experts; Ghost Infer measured a loss on CUDA and disables it for MoE. The adaptive controller should back off automatically, and the run will show whether it does.
   - The prefix-reuse gains should transfer fully.
2. **A dense coding model** (e.g. Qwen2.5-Coder-7B MLX). Speculation gains depend on how faithfully the model copies context, so the general-purpose Llama-3-8B is a proxy only.
3. **Concurrency.** `RuntimeLifecycleManager` allows 2 concurrent runtimes. Measure two persistent workers under load, including the live caches.

## P2: engineering work suggested by Ghost Infer

1. **Exact sampled acceptance** (Ghost Infer `Sampler::accept`), so lookup speculation also applies at temperature > 0. Lookup drafts are deterministic (one-hot proposals), so the acceptance rule is simple: accept with p(x); on rejection, resample from p with x removed.
2. **Saved "openings"** (Ghost Infer `Engine::opening`): keep up to N system-prompt prefixes (≥512 tokens) in RAM keyed by token hash, so Ashex switching between agent and subagent prompts reuses them. This is a natural extension of `live` mode (multi-slot, keyed by prefix rather than state-file path).
3. **Upstream to mlx-lm:** a `prompt_lookup` mode in `stream_generate` (the bridge implementation is self-contained). Also investigate batch-invariant verify, i.e. a `qmm` path whose reduction order matches `qmv`, so speculation is bit-exact like Ghost Infer's verify kernels.
4. **Upstream to llama.cpp:** report the b8660 `--spec-type ngram-map-k` server crash with a reproduction.
5. **Parse llama-server `timings`** in `LlamaServerRuntime` (prefill and decode tok/s, draft acceptance) so esh's metrics stop reporting time to first token only for GGUF.
6. **Add `MemorySafetyPreflight` to the `RuntimeLifecycleManager` loader** (the serve/CLI path relies only on the pool estimate today).
7. **Fix `esh optimize benchmark`** (Apple-only registry, so MLX/GGUF hit `preconditionFailure`).

## P3: needs other hardware or bigger bets

1. **Ghost Infer as an optional backend for Windows/Linux + NVIDIA esh.** Wait for a Linux build, a stable release, and auth on `/v1`; run it sandboxed as a subprocess. Its MoE expert cache is the right tool for "MoE larger than VRAM" on discrete GPUs.
2. **SSD→RAM expert residency** using Ghost Infer's frequency-gated LRU and trace replay, for MoE models larger than RAM. Deprioritized: esh measured about 1 GB/s on the external SSD, and its policy is to keep models resident via mixed quantization.
3. **Hadamard-rotated 4-bit KV** for 256-wide heads (Qwen3.5/3.6 family), if those models become esh defaults and long-context memory matters.
