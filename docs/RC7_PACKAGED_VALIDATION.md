# esh 2.0.0-rc.7 — Packaged / Notarized Validation Report

**Tag:** `v2.0.0-rc.7` · **Commit:** `f49b844` · **Date:** 2026-09-02
**Artifact:** `esh-macos-2.0.0-rc.7.zip` (notarized, downloaded from the GitHub prerelease)
**Verdict:** ✅ **READY FOR FINAL 2.0**

Both runaway-generation blockers (GGUF, rc.6 → resident `llama-server`; MLX, rc.7 → stop at
turn/EOS special tokens) are fixed and validated on the actual notarized artifact.

## Release settling
| Check | Result |
|---|---|
| GitHub Release exists · Prerelease | ✅ · ✅ (`prerelease=true`) |
| Sign · Notarize | ✅ · ✅ (release job: "Sign release payload", "Notarize release archive" → success) |
| Artifacts · Checksums | ✅ 4 assets · ✅ `.sha256` present, **matches** |
| Stable Homebrew cask | ✅ untouched (`version "0.9.7"`; cask steps skipped for prerelease) |
| Latest release | ✅ `Esh 0.9.7` (stable users not auto-upgraded) |
| Older RC tags | ✅ rc.1–rc.6 unchanged |

## Artifact inspection
| Check | Result |
|---|---|
| Checksum | ✅ match (`6c01631c…`) |
| codesign | ✅ Developer ID Application: Sviatoslav Fil (L7T5538V86), full Apple chain, timestamped (esh + llama-server); deep-verify valid |
| Gatekeeper | ✅ origin recognized as Developer ID (CLI reports "not an app", expected for a non-.app executable) |
| `esh version` | ✅ `2.0.0-rc.7` (the actual notarized binary) |
| Hard-coded paths | ✅ no dev/functional CI-path leaks; 28 `/Users/runner` strings are inert mlx-swift C++ `__FILE__` debug metadata; `/opt/homebrew` only as optional fallback search paths |
| `llama-server` bundled | ✅ `share/esh/bin/llama-server` (15.9 MB), **links only system frameworks** — no `@rpath`/Homebrew/openssl/ggml dylibs |

## GGUF battery (packaged, run in a **no-Homebrew** environment)
Model: `bartowski--llama-3.2-3b-instruct-gguf`. The running server was verified to be the **bundled**
`share/esh/bin/llama-server` (PATH excluded `/opt/homebrew`).

| Case | Result |
|---|---|
| Runaway repro (multi-turn) | ✅ `finish_reason: stop`, **no fake `User:` turns**, complete 816-char answer (not a 400-token runaway) |
| Literal `User:` in output | ✅ produced legitimately, **not truncated** |
| Multi-turn history | ✅ correct |
| Warm residency | ✅ cold 17.0 s → warm **0.24 s** (model resident, no reload) |
| Streaming (SSE) | ✅ 12 events |
| Cancellation | ✅ aborted mid-stream; server survived; next request works |
| Custom stop sequence | ✅ stopped before `four` |
| Max-tokens cap | ✅ capped independent of natural EOS |
| Strict JSON Schema | ✅ **valid JSON** `{"name":"Alice","age":30}` via native constrained decoding |

## MLX battery (packaged)
| Case | Result |
|---|---|
| DeepSeek-R1-Distill-Qwen-7B (reasoning) | ✅ `finish stop`, **no leaked special tokens, no fake turns**, clean answer with `<think>` reasoning |
| Llama-3.2-3B-Instruct MLX | ✅ clean, no leaks |
| Strict JSON schema on MLX | ✅ honestly **rejected** ("Strict structured output rejected") — unchanged (verified at source; identical Swift service code in the packaged binary) |
| Warm residency | ✅ warm 7B request 1.90 s |

## Metal acceleration (§5)
Bundled `llama-server`, direct run: `GPU name: MTL0`, `GPU family: MTLGPUFamilyApple7`, embedded metal
library, residency sets. Throughput **129 tok/s prompt · 55 tok/s generation** (3B Q4) — unmistakably
Metal, **not** a CPU fallback. (First-ever GGUF call pays a one-time ~9.6 s Metal shader compile.)

## No external runtime dependency (§6)
Packaged esh launched with `PATH=/usr/bin:/bin` (no `/opt/homebrew`) and no `ESH_LLAMA_CPP_*` override.
GGUF worked end-to-end using the **bundled** `llama-server`; the running process path is inside the
package; no plugin-tree lookup outside the package. **Self-contained confirmed.**

## Regression smoke (§7)
| Area | Result |
|---|---|
| MLX inference · persistent residency | ✅ · ✅ (warm 1.9 s) |
| Auto / Scheduler | ✅ routed to a model, no error |
| Web Chat | ✅ loads (148 KB, self-contained, no external `src`) |
| Reasoning | ✅ (DeepSeek reasoning clean) |
| Apple Foundation Models | ✅ on-device "Hello" |
| STT · TTS · voice server path | ✅ TTS→WAV→STT round-trip: "Hello from Esh." |
| Doctor | ✅ status ok; **llama.cpp ready** (bundled server detected, no Homebrew), **mlx ready**, Apple available; honestly flags corrupt `qwen2.5-0.5b` |
| Storage | ✅ external SSD available, 1231 GB free |

## GGUF / MLX runtime compatibility matrix
| Model | Backend | Packaged result |
|---|---|---|
| Llama-3.2-3B-Instruct (GGUF) | llama-server (Metal) | ✅ correct stop, JSON schema, streaming, Metal |
| Llama-3.2-3B-Instruct (MLX) | mlx-lm | ✅ clean |
| DeepSeek-R1-Distill-Qwen-7B (MLX) | mlx-lm | ✅ clean reasoning, no leaks |
| Qwen3.5-9B (MLX) | mlx-lm | ⚠️ special-token leak fixed; plain-text rambling is the model's own hybrid/SSM incompatibility — **gated** from recommendations for 2.0 |
| Qwen2.5-0.5B (MLX) | — | ⚠️ install incomplete/corrupt on this machine (files missing); doctor reports it, UI shows the friendly "not available" card |
| Apple Foundation Models | Apple on-device | ✅ |

## Known issues (non-blocking)
- `qwen2.5-0.5b-instruct-4bit` is an orphaned/corrupt local install (files missing) — reported honestly
  by doctor and surfaced as a friendly error card in the web UI; user-data issue, not a runtime defect.
- `Qwen3.5-9B` is gated (hybrid/SSM path incompatible with current mlx-lm); the rc.7 fix stops its
  special-token leak, but its reasoning rambling is inherent to the incompatible model.
- Real-microphone voice remains environment-limited (server STT/TTS verified; live capture needs a real
  browser) — not automated-E2E.
- First GGUF call on a fresh machine pays a one-time ~9.6 s Metal shader compile.

## Remaining blockers for final 2.0
**None found.**
