# Ghost Infer study (2026-11)

Ghost Infer was reviewed at revision `2f2a985bf74c8e0e4b288cadb68e77bfc9a554de` (MIT OR Apache-2.0).

| Doc | Contents |
|---|---|
| [A-ghost-infer-source-study.md](A-ghost-infer-source-study.md) | Ghost Infer architecture, algorithms, claims and limits, with file:line citations at the pinned SHA |
| [B-esh-inference-audit.md](B-esh-inference-audit.md) | esh's backends, knobs, lifecycle and guarding, plus the defects found |
| [C-integration-decision.md](C-integration-decision.md) | Backend: no. Per-capability decisions, upstream vs fork, defaults |
| [D-benchmark-report.md](D-benchmark-report.md) | Reproducible baseline and post-change measurements (M1 Pro, 32 GB) |
| [F-roadmap.md](F-roadmap.md) | Prioritized follow-ups |
| [H-final-production-readiness.md](H-final-production-readiness.md) | Final readiness: merge status, KV-growth guard, Ashex and `esh serve` validation, recommended defaults |
| [G-production-hardening-report.md](G-production-hardening-report.md) | Follow-up: production hardening, validation and merge readiness (branch `perf/inference-hardening`) |

Implementation (branch `perf/ghost-infer-learnings`; everything is **opt-in**, defaults unchanged except the disk guard):

| Flag | What it does | Commit |
|---|---|---|
| `ESH_MLX_LOOKUP_SPEC=1` (+ `ESH_MLX_LOOKUP_MAX_DRAFT`, `_MIN_MATCH`, `_ADAPTIVE`) | MLX prompt-lookup speculative decoding, greedy only | `51fc115` |
| `ESH_LLAMA_SPEC_TYPE=ngram-simple` (+ `ESH_LLAMA_DRAFT_MAX`, `ESH_LLAMA_KV_TYPE`) | Upstream llama.cpp n-gram speculation and KV type, allow-listed | `cda03db` |
| `ESH_MLX_PREFIX_CACHE=tokens\|live\|legacy` (+ `ESH_MLX_LIVE_PREFIX_SLOTS`) | Token-exact prefix reuse, **`tokens` is the default** since 2026-11-14; `live` adds an in-memory session cache in the persistent worker (opt-in); `legacy` is the rollback | `b9c8d0c` |
| (always on) | Skip KV snapshots that would exhaust the internal/swap volume | `4c6813c` |

Reproduce: `~/.esh/runtime/py311/venv/bin/python benchmarks/esh_infer_bench.py --help`, then
`python benchmarks/summarize_bench.py --labels <label…>`.
Tests: `~/.esh/runtime/py311/venv/bin/python -m unittest discover -s Tests/Python -p 'test_*.py'`, and
`swift test --filter LlamaServerTuningTests`.
