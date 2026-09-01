# esh 2.0.0 — Release Report & RC Readiness (Phase S)

**Date:** 2026-09-01
**Status:** merged to `main`; `VERSION = 2.0.0-rc.1`; release pipeline made RC-safe (prerelease flag +
stable Homebrew cask protected). Awaiting `v2.0.0-rc.1` tag + CI.
**Version story (reconciled):** `0.9.8` was an unreleased repository version only (never tagged); the
latest public stable before this RC was `v0.9.7`. The 0.9.8 work is folded into this RC — no standalone
`v0.9.8` release is created (no user-facing reason to). See `CHANGELOG.md`.
**Companion docs:** `2_0_RC_AUDIT.md`, `2_0_COMPATIBILITY_MATRIX.md`, `2_0_SECURITY_PRIVACY_REVIEW.md`,
`2_0_API_SEMVER_CONTRACT.md`, `2_0_STRESS_REPORT.md`, `2_0_MIGRATION_REPORT.md`.

## 1. What this program changed (all committed on the branch)

1. **Rich Web Chat UX + STT endpoint** — ChatGPT-like client (history, model picker, settings,
   collapsible reasoning, markdown, image/audio, attachments, per-message TTS, mic upload) and a new
   `POST /v1/audio/transcriptions` route.
2. **Blocker B1 (qwen3.5)** — the flagship default was a **known-broken** model. All MLX Qwen3.5
   (hybrid, crashes on current mlx-lm) reclassified `.incompatible`; flagship default → **Mistral
   Small 24B** (owner decision); onboarding starter fixed; GGUF variant → experimental.
3. **Blocker B2 (Marvis TTS)** — advertised-but-broken; filtered from the catalog; explicit request →
   honest 400.
4. **Blocker B3 (GGUF/llama.cpp)** — current `llama-cli` removed `--no-conversation` and esh **hung
   forever** on every GGUF run. Fixed to prefer `llama-completion`; verified text + native strict JSON
   constrained decoding end-to-end.
5. **Cross-backend capability matrix** + conformance coverage (Apple/ONNX reasoning).
6. **Hardening** — request-body cap, wildcard-bind warning, `esh model recommended` hides
   incompatible by default.
7. **Docs** — truthful roadmap, security/privacy review, API/SemVer contract, stress + migration
   reports, and this audit.

## 2. Gate status

| Criterion | State |
|---|---|
| Build + full test suite | ✅ **309/309** green |
| No default/recommended model known-broken (B1) | ✅ closed + tested |
| No "supported" label on a broken model (B2) | ✅ closed + verified |
| GGUF backend works on current llama.cpp (B3) | ✅ closed + verified (text + native JSON) |
| MLX generation | ✅ verified (Llama 3.2 3B, DeepSeek-R1 7B) |
| Persistent residency + no orphans | ✅ verified (~10× warm, clean shutdown) |
| Scheduler avoids broken models | ✅ verified (measured evidence) |
| Cross-backend capability honesty | ✅ test-enforced |
| TTS | ✅ verified (real WAV) |
| STT endpoint plumbing | ✅ verified (transcription itself needs bundled `mlx_audio`) |
| Security/privacy | ✅ reviewed, no high-severity; 2 recs implemented |
| API/SemVer contract | ✅ documented |
| Docs truthful | ✅ done |
| Concurrency stability (short) | ✅ 8/8, stable |

### Validated during RC staging (2026-09-01)
- **A1 version story** — reconciled (see top): 0.9.8 unreleased, folded into RC; no standalone v0.9.8.
- **Live browser interaction (I) — VALIDATED in a real browser** against the served Web Chat: open/
  render, model switching, streaming, send, conversation history (create/list/switch/**persist across
  reload** via localStorage), **reasoning collapse + expand** (DeepSeek-R1: "17 plus 26 equals 43"
  with a collapsible ▶/▼ Reasoning section), settings panel (system prompt/temperature/max-tokens/
  reasoning/cache/auto-TTS), **TTS** (synthesizing→ready), and usage/ExecutionProfile display
  ("Ns · N chars"). The page footer shows `esh v2.0.0-rc.1`. Only file-dialog flows (attachment/STT
  upload) need an OS picker not drivable here; the STT endpoint itself is verified via curl.
- **Fresh environment (K) — VALIDATED (config isolation)** via `ESH_HOME`/`ESH_ASSETS_HOME`: fresh
  state root resolves correctly, `model list` handles empty state, `onboard status` reports fresh
  state (chip/memory/engines detected), `model recommended` shows the Mistral flagship with no
  qwen3.5. No existing state/config silently required. *(Packaged-binary-without-source remains for the
  RC artifact — the dev build still needs the source tree for the MLX Python bridge.)*

### Still open before **GA** (env-limited or requires the packaged RC artifact)
| Item | Why still open |
|---|---|
| Live mic capture + real STT transcription (J) | needs bundled `mlx_audio` (packaged RC) + a mic |
| Packaged binary without source (K, remainder) | verify on the notarized RC artifact |
| Packaged cross-version upgrade (L) | needs historical released binaries |
| Multi-hour soak + large-model pressure (P) | needs a longer-running, less disk-constrained host |
| Host disk pressure (M) | internal Data volume ~full on this host |

## 3. Recommended RC cut steps (owner action — outward-facing publish)

These are **left for the owner** because tagging triggers the notarize/GHCR/Homebrew publish pipeline
and some validations above need a real environment. The engineering is ready; the cut is a decision.

1. **Reconcile the version story (A1):** decide whether to publish the 0.9.8 work under `v0.9.8` first
   or fold it into 2.0. Then set `VERSION` to `2.0.0-rc.1` and update `CHANGELOG.md`.
2. Merge `codex/web-chat-rich` → `main` (review the 8 commits from this program).
3. On a machine with adequate free disk, run the packaged build + `swift test` (expect 309 green).
4. Tag `v2.0.0-rc.1` to trigger `release.yml` (codesign + notarize + GHCR + Homebrew cask).
5. Run the env-limited validations (I/J/K/L/M/P) against the RC build; iterate `-rc.N` as needed.
6. Only when those are green: cut **`v2.0.0`**.

## 4. Verdict

The 2.0 **engineering gate is green**: all three real compatibility blockers are closed and verified,
the build/test baseline is strong (309/309), and the contract/security/API posture is documented and
honest. **2.0.0 is NOT yet released** — per the standing rule "do not release 2.0 merely to finish the
task," the RC cut and the env-limited validations are deliberately left to the owner and a suitable
environment. This branch is a ready, honest **release candidate in engineering terms**, pending the
version-story reconciliation and the outward-facing publish.
