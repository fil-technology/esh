# M11 — Hardening / Release-Candidate Report

Consolidated production-readiness status. Emphasis on **real evidence**: every item below was
exercised on the actual dev/released binaries, not mocks. Several real bugs were found and fixed this
way — the point of a hardening pass.

## Surfaces smoke-verified (dev binary, this pass)

| surface | result |
|---|---|
| `esh version` | ✓ reports real version |
| `esh doctor` | ✓ exit 0 |
| `esh model list` / `capabilities` / `storage show` | ✓ |
| `esh model recommended --explain` | ✓ marks "★ measured on your Mac" from Benchmark Lab |
| `esh schedule --goal general --quality high` | ✓ picks working 3B, skips measured-broken 9B |
| MLX inference | ✓ |
| Apple routable inference (`--model apple-intelligence`) | ✓ on-device |
| strict structured output | ✓ **honestly rejected** (not faked) |
| STT (`esh audio transcribe hello.wav`) | ✓ "Hello from Esh." |

## Released-binary verification (this session)

Every release 0.8.1 → 0.9.3 was verified on the **installed, notarized** binary: `spctl` accepted
(Notarized Developer ID, hardened runtime), `brew upgrade` across versions, `esh version` correct,
bare-`esh` MLX inference, Apple routable backend, cask upgrade. Distribution chain (GitHub release +
4 artifacts + checksum + Homebrew cask + GHCR) verified each time.

## Real bugs found and fixed this session

1. **Packaged-binary runtime discovery** used `argv[0]`; bare `esh` (Homebrew) broke MLX + reported
   `version unknown`. Fixed via `_NSGetExecutablePath` (0.8.1).
2. **ExFAT free-space** reported 0 (APFS-only key), blocking downloads/Model Fit on the external SSD.
   Fixed (0.9.3).
3. **MLX bridge crash** on newer cache types (`ArraysCache` has no `.offset`). Fixed (0.9.3).
4. **Benchmark probes unfair to reasoning models** (cut off `<think>` chains). Fixed (0.9.3).

## Known findings (measured, truthfully recorded — not force-patched)

1. **qwen3.5-9b** is catalog-recommended but fails to run on the installed mlx-lm
   (`create_attention_mask` signature mismatch) — the Scheduler now skips it on measured evidence.
2. **Marvis TTS model** fails to load (RoPE-key/version mismatch) — `esh audio speak` is currently
   blocked with the default model; STT is unaffected. See SPEECH_REPORT.md.
   Both are runtime/model **version mismatches** that need a dependency/model-revision fix + regression
   check, not a blind patch.

## Not yet verified (environment constraints — flagged, not claimed)

- **Interactive Terminal UX** (streaming, Ctrl-C, slash commands live) — needs a TTY; pure
  formatting/parsing is unit-tested, wiring uses real dataflow.
- **Web Chat in a browser** — server side verified via curl (`GET /web` → 200 text/html, `/v1/models`
  feeds the picker); browser rendering/streaming not verified here.
- **Live TTS audio playback**, memory-pressure stress at scale, multi-client concurrency soak, and
  crash-recovery under load — need dedicated runs.

## Verdict

The core engine — models, inference (MLX + Apple), optimization, Model Fit, lifecycle/persistent
residency, caches, benchmarking, hardware-aware scheduling, and STT — is **verified on real binaries**
and behaves truthfully (honest capability resolution, measured evidence overriding curated claims, no
fabricated metrics). Two model/runtime version mismatches (qwen3.5-9b, Marvis TTS) and the
interactive-surface live verifications are the remaining gates before a `2.0.0` call — which should not
be made until those are closed and the interactive/audio/browser flows are verified on a packaged
build. **Not 2.0.0 yet**, by evidence.
