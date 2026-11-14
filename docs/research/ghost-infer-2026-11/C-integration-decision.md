# Ghost Infer: integration decision

**Decision.** Do **not** add Ghost Infer as a backend or a dependency. Take its *hardware-agnostic algorithms*
into esh's existing MLX and llama.cpp backends (Option A, plus a small Option B port of one algorithm), behind
opt-in flags. Revisit Option C only for a future Windows/NVIDIA esh target, and only once the project has matured.

Ghost Infer revision reviewed: `2f2a985bf74c8e0e4b288cadb68e77bfc9a554de` (v0.4.0, 2026-11-14), licensed MIT OR
Apache-2.0. Evidence: [A-ghost-infer-source-study.md](A-ghost-infer-source-study.md) and
[D-benchmark-report.md](D-benchmark-report.md).

## Why not a backend (Option C)

| Question | Finding |
|---|---|
| Does it run on macOS / Apple Silicon? | **No.** By inspection, it doesn't compile off Windows at this revision: unguarded `std::os::windows` imports in `src/tools.rs`, `src/server/download.rs` and `src/server/mcp.rs`. The GPU path is Windows-only (`nvcuda.dll` plus NVRTC; a stub elsewhere). There is no Metal and no NEON. Even patched, it would run CPU-only and scalar. |
| GGUF/model compatibility | It is a subset of llama.cpp: 7 architectures and GPT-2-style BPE tokenizers only. Several quant types esh uses (Q2_K, IQ4_XS, IQ1, MXFP4) are missing, and Q4_K_M MoE experts can't use its expert cache. |
| API | An OpenAI-compatible server, but with no `response_format`/json_schema/grammar. esh's GGUF path relies on `json_schema` and `grammar`. |
| Maturity / maintenance | 3 weeks old, about 139 commits, effectively one author, and a very large non-inference surface (agent, MCP, plugins, nightly training). |
| Security | `/v1` has no authentication and `Access-Control-Allow-Origin: *`. Agent features run PowerShell with `-ExecutionPolicy Bypass` and import Claude Desktop's MCP config. Using it as a subprocess backend would need sandboxing and auth that esh would have to own. |
| Would it help on this hardware? | Its headline wins are (a) a VRAM expert cache for MoE models larger than a discrete GPU, and (b) CUDA-specific kernels and graphs. On unified memory there is no separate VRAM to cache into, and CPU and GPU share one bandwidth pool. Moving cold experts to the CPU gains no bandwidth. |

A future **Windows/Linux + NVIDIA** esh could reasonably host it as an optional, sandboxed `llama-server`-style
subprocess (MoE larger than VRAM is exactly its niche). That would need a stable release, a Linux build, an auth
token on `/v1`, and its agent features off. It is listed on the roadmap; no work now.

## Per capability

| Ghost Infer technique | Apple Silicon applicability | Decision | Status in esh |
|---|---|---|---|
| Prompt-lookup speculation with an adaptive controller (`src/lookup.rs`) | **Fully applicable**; hardware-agnostic | **Option B (algorithm port) for MLX**: mlx-lm has no n-gram mode | Implemented, flagged `ESH_MLX_LOOKUP_SPEC=1`. Code edits on Llama-3-8B: +75% decode, −37% end-to-end; neutral elsewhere |
| Same idea for GGUF | Upstream llama.cpp b8660 already has `--spec-type ngram-*` | **Configure upstream, don't re-implement** | Exposed via `ESH_LLAMA_SPEC_TYPE` (allow-listed). `ngram-simple`: code edits about 3.4× on 1.5B |
| Batch-invariant ("bit-identical") verify kernels | The principle applies; MLX's `qmm` (batched) and `qmv` (single-token) kernels round differently | **Upstream (MLX) candidate**, not a fork | Measured instead: 14/15 outputs identical; divergences are floating-point near-ties |
| Exact sampled acceptance (`Sampler::accept`) | Applicable | Roadmap: extends lookup speculation beyond temperature 0 | Not implemented (greedy only) |
| Session prefix reuse | Applicable | Fix esh's broken reuse (exact tokens, longest common prefix, trim) | Implemented, flagged `ESH_MLX_PREFIX_CACHE=tokens\|live` |
| System-prompt "openings" kept in RAM | Applicable (agent ↔ subagent switching) | Roadmap: follows naturally from `live` mode with more slots and a prefix key | — |
| VRAM expert cache (frequency-gated LRU) | **Doesn't transfer** as a VRAM cache. The *policy* could apply to SSD→RAM expert residency, but esh's measured SSD ceiling (about 1 GB/s) already rejected expert streaming | Rejected for now | — |
| CPU execution of cold experts | Shared bandwidth on unified memory, so no gain expected | Rejected | — |
| Per-layer CUDA graphs, mapped-memory routing handshake | CUDA-specific; MLX already fuses and launches lazily | Rejected | — |
| int8 / Hadamard-rotated 4-bit KV | Applicable as a memory lever. esh already has uniform KV quantization (MLX), TurboQuant and TriAttention, and now `-ctk/-ctv` for GGUF. At short context it measured −13…−20% decode on llama.cpp/Metal | Keep as an opt-in for long context | Exposed |
| KV growth in 4K steps | MLX's `KVCache` already grows in steps (256) | Already present | — |
| Layer-ahead disk prefetch for prompts | Only matters out-of-core | Rejected (esh keeps models resident by policy) | — |

## Upstream vs fork

- **mlx-lm**: a prompt-lookup mode in `stream_generate`, plus batch-invariant verify, would serve every MLX user. The
  bridge implementation is small and self-contained, so propose it upstream rather than fork mlx-lm.
- **llama.cpp**: nothing to fork. Report the `ngram-map-k` server crash upstream, with a reproduction.
- **Ghost Infer**: nothing vendored. The lookup algorithm was re-implemented in Python for MLX with attribution. Its
  license (MIT OR Apache-2.0) permits adaptation.

## Defaults

Nothing is turned on by default. Recommendations to promote, after the follow-ups in [F-roadmap.md](F-roadmap.md):

1. `ESH_MLX_PREFIX_CACHE=tokens`: it fixes a correctness defect (duplicated tokens in the legacy hit path) and a
   performance defect (no hits). It should become the default after a soak in `esh serve` with real Ashex sessions.
2. Lookup speculation (MLX) and `ngram-simple` (GGUF) for `code` / `agentrun` intents only, driven by the existing
   intent-based `auto` mode, never for chat.
