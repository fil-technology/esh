# esh 2.0.0 — Release Report

**Status:** ✅ **RELEASED AND VERIFIED** (stable) · **Date:** 2026-09-02

esh 2.0.0 is the culmination of the RC program. The final tag is a promotion of the packaged-validated
`v2.0.0-rc.7` tree (behaviorally identical — only VERSION/CHANGELOG/docs differ). The stable artifact
was installed via the real Homebrew end-user path and smoke-validated.

## Release facts
| Item | Value |
|---|---|
| Final commit | `1e28a46` (VERSION `2.0.0` + CHANGELOG only; docs-only diff from rc.7 `f49b844`) |
| Tag | `v2.0.0` |
| CI run | `33602739331` — Test and Verify + Package Smoke → **success** |
| Release run | `33603961647` — Sign + Notarize + Publish + Homebrew cask update → **success** |
| Tests | **343 Swift (59 suites) + 9 Python = 352 green** |
| Artifacts | `esh-macos-2.0.0.{tar.gz,zip}` + `.sha256` (GitHub release) |
| Checksum | zip sha256 `faf786eec2975803122f1770bd197202dc1c1829059c6887785c4b14acafa284` (brew verified on install) |
| Notarization / codesign | Notarized; **Developer ID Application: Sviatoslav Fil (L7T5538V86)** on `esh` + `llama-server` |
| GitHub Latest | **Esh 2.0.0** (prerelease=false); RCs remain prereleases |
| Homebrew cask | **`version "2.0.0"`** (upgraded from 0.9.7); `brew upgrade --cask fil-technology/tap/esh` takes 0.9.7 → 2.0.0 |

## Release-channel transition (verified)
- `v2.0.0` is GitHub **Latest**; RC tags stay **Pre-release** (stable users were never auto-upgraded during the RC program).
- Stable Homebrew cask updated 0.9.7 → **2.0.0**; a real `brew upgrade --cask` on this machine upgraded 0.9.7 → 2.0.0 successfully.
- `esh update check` on the stable build reports **current 2.0.0 / up to date**, update path `brew upgrade --cask esh`.

## Stable-artifact validation (brew-installed 2.0.0)
Validated via `/opt/homebrew/bin/esh` (Caskroom 2.0.0) — the exact end-user binary.

| Area | Evidence |
|---|---|
| `esh version` | `2.0.0` |
| Gatekeeper / codesign | Developer ID Application (valid) |
| `esh doctor` | status ok · Apple M1 Pro · **llama.cpp ready** · **mlx ready** · Apple Intelligence available; honestly flags corrupt `qwen2.5-0.5b` |
| **GGUF** | natural stop (runaway repro → `finish stop`, no fake `User:` turns); multi-turn; **strict JSON Schema** → valid `{"name":"Alice","age":30}`; streaming (SSE); Stop/cancel (server survives) |
| **Bundled `llama-server`** | the running server is the **Caskroom** `share/esh/bin/llama-server` — **not** `/opt/homebrew/bin` — even with Homebrew in PATH |
| **No Homebrew llama.cpp dependency** | ✅ self-contained (system frameworks only) |
| **Metal** | GPU `MTLGPUFamilyApple7`, embedded metal library, ~55 tok/s (3B Q4) — not CPU fallback |
| **MLX** | DeepSeek-R1-Distill reasoning clean (no leaked special tokens, no fake turns); warm residency **0.56 s** |
| **Apple Foundation Models** | on-device "Hello." |
| **Web** | `esh web` loads (148 KB, self-contained); chat/streaming/Stop; engine/schedule/models endpoints 200 |
| **Speech** | TTS → valid WAV; STT round-trip "Hello from Esh."; server-side voice pipeline |
| **Storage** | external SSD available |
| Scheduler / Auto · Model Fit · recommendations | Auto routes with rationale; doctor + registry honest |

## Known limitations (honest, non-blocking)
- Orphaned/corrupt local `qwen2.5-0.5b-instruct-4bit` install (files missing) — user-state/model-data
  specific; doctor reports it honestly and the web UI shows a friendly "not available" card.
- `Qwen3.5-9B` MLX remains **gated incompatible** (hybrid/SSM path vs current mlx-lm); the rc.7 fix stops
  its special-token leak, but its reasoning rambling is inherent to the incompatible model.
- Real-browser microphone capture remains **environment-limited** in automated validation (server
  STT/TTS + loop logic verified; live capture needs a real browser).
- First-ever GGUF call on a fresh machine pays a one-time ~9.6 s Metal shader compile.

## Post-2.0 — urgent roadmap
- **Warm TTS / persistent speech runtime** — hold a long-lived TTS synthesizer so `/v1/audio/speech`
  doesn't reload the model per call. Deferred deliberately; **not** unfinished 2.0 scope.

## References
- `docs/RC7_PACKAGED_VALIDATION.md` — full rc.7 packaged/notarized validation + GGUF/MLX compat matrix.
- `RC3_SOAK_CHECKLIST.md` — soak log (verified vs environment-limited).
- `docs/ROADMAP_STATUS.md` — milestone completion.
- ClickUp: master roadmap `86eyt96nn`, Web Experience `86eytj9rg` (accomplishment summaries posted).
