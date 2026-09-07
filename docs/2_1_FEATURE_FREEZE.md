# esh 2.1 — Feature Freeze

```
ESH 2.1 FEATURE FREEZE — CONCLUDED (v2.1.0 released 2026-09-07)
```

> **CONCLUDED 2026-09-07.** `v2.1.0` is released and verified (stable tag `v2.1.0` → `0e2405b`, GitHub
> Latest, Homebrew cask `2.1.0`; see CHANGELOG `[2.1.0]` and `docs/2_1_RC2_PUBLISHED_AND_VERIFIED.md`). The
> freeze below governed the run-up to the release and is now lifted. Post-2.1 work resumes under normal
> planning (2.2+); do **not** begin 2.2 as a side effect of this note.

**Effective:** 2026-09-06, immediately after Voice 2.1 merged to `main` (PR #8, merge `63552f4`).
Voice was the final major capability addition for 2.1.

## Until `v2.1.0` ships, do NOT begin
- Video **generation**
- Audio editing / stems / separation / remix / music extend
- Tier C Node
- Autonomous / Ashex functionality
- New modality families
- Speculative architecture

## Allowed during the freeze
- Release blockers; crashes/regressions
- Install / update / routing / model / storage / memory-pressure bugs
- Broken capability paths
- Security / sandbox issues
- Serious UX problems
- Diagnostics (`esh doctor`)
- Documentation
- Packaging & release qualification

Everything else → **2.2+**.

## The question 2.1 must answer
> Can someone who did not build esh install it, understand it, trust it, recover from failures, and reliably
> use the capabilities we claim are production-ready?

Optimize for reliability, installation, recovery, documentation, polish, and trust — not feature count.
