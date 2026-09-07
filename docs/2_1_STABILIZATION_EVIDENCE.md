# esh 2.1 — Stabilization Evidence (Phase 4/6, running)

Verified against `main` (post Voice merge `63552f4`). This log converts qualification-matrix `○` cells toward
`✅` as real end-to-end runs land. It is additive — dimensions not yet exercised stay honestly unproven.

## Core public path (verified 2026-09-06)
| Check | Result |
|---|---|
| `GET /health` | ✅ 200, routes listed |
| `GET /v1/models` | ✅ 16 models |
| `GET /v1/audio/models` | ✅ 38 audio models |
| `POST /v1/chat/completions` cold (llama-3.2-3b) | ✅ correct ("PONG"), ~17.3 s cold load |
| `POST /v1/chat/completions` warm | ✅ correct ("4" for 2+2); ~11.9 s wall (model reloaded between separate requests without `ESH_MLX_PERSISTENT`; correctness, not latency, is the smoke's claim) |
| Voice realtime `/voice` (Gate suite) | ✅ cold+warm+offline (see `2_1_VOICE_CLOSURE_STATUS.md`) |

## Notable
- Warm chat latency in the smoke is dominated by re-residency, not inference — the runtime evicts between
  isolated requests; with a resident session (chat UI / `ESH_MLX_PERSISTENT`) it stays warm. Not a blocker;
  flagged for the latency pass.

## Still to exercise end-to-end before RC1 (remain `○` in the matrix)
- `/v1/execute` per-capability cold+warm: image.understand/OCR/generate/edit/upscale, vector/webArtifact/
  project/Three.js, video.understand, SFX. (Model-heavy; run selectively with the right installed models.)
- Fresh-user lifecycle on an isolated managed root (Phase 5): missing-model → Fit → install → resume →
  execute; SSD available/missing/disconnected/reconnected; low disk; interrupted/failed install; cancel/retry.
- Failure/recovery matrix (Phase 6): incompatible model, low RAM/disk, memory pressure, disconnected storage,
  runtime crash, malformed output, cancellation, browser refresh, server restart, offline, concurrency.
- Packaged-path smoke on a FRESH notarized artifact (Phase 10) — not the stale `dist/`.
