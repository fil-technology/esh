# esh 2.0.0 — Release Report & RC Readiness (Phase S)

**Date:** 2026-09-01
**Branch:** `codex/web-chat-rich` (off `main` @ 0.9.8) — **not yet merged/tagged**
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

### Still open before **GA** (honest — env-limited or owner-only)
| Item | Why still open |
|---|---|
| **A1 version story** | `main` says 0.9.8 but latest published is v0.9.7; 0.9.8 never tagged. Must reconcile to the 2.0 line before cutting the RC. |
| Live browser interaction (I) | non-interactive session |
| Live mic capture + real STT transcription (J) | needs bundled `mlx_audio` + a mic |
| Fresh clean-machine run (K) | needs a second/clean machine |
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
