# esh 2.0.0 — Upgrade / Migration Report (Phase L)

**Date:** 2026-09-01

## Migration design (verified in code)

- **Config (`~/.esh/config.toml`)** carries `schema_version` (`[meta] schema_version = 1`). `EshConfig`
  decodes every field with `decodeIfPresent` + defaults, so **older configs load unchanged** and
  **new optional keys** (`tts_model`, `stt_model`) appear with safe empty defaults. Unknown/al future
  keys do not break decoding.
- **Deprecated keys are retained, not dropped.** e.g. `model_dir` is preserved with an explicit
  "deprecated / kept for backward compatibility" comment; storage is now managed by `esh storage`.
- **Storage config** (`.esh-storage.json` on the storage volume) and per-model manifests are versioned
  and read through the persistence layer; migration hooks exist in `PersistenceRoot`, `StorageConfig`,
  `StorageService`, and `OnboardingService`.

## Real-world evidence (this session)

The current 2.0-track binary was run against a **live `~/.esh` created and updated by older esh
versions across April–September 2026** (directory timestamps span months):

- `esh config show` cleanly rendered the existing `config.toml` (schema_version=1, deprecated
  `model_dir` preserved, new speech keys present).
- `esh doctor --json` reported `status: ok` and read the external-SSD storage config (models/caches/
  audio/temp classes) written by earlier versions.
- `esh model list` / `esh schedule` operated over models installed by earlier sessions on the SSD.

This is genuine **forward-compatibility evidence**: data written by older versions is consumed by the
new build without loss or error.

## Not covered here (environment-limited — labeled, not claimed)

A full **old-binary → new-binary upgrade matrix** (install v0.7/v0.8/v0.9 fresh, then upgrade in place
and diff behavior) requires installing multiple historical released binaries, which this session's
environment cannot stage cleanly. The forward-compat of the **data/config formats** is verified above;
what remains is exercising the packaged **Homebrew cask upgrade** path (`brew upgrade --cask esh`)
across several prior releases on a suitable machine.

## Recommendations before GA

1. Run `brew upgrade --cask esh` from at least v0.7.0 and v0.9.7 to 2.0 on a test machine; confirm the
   binary, bundled Python/llama.cpp, and config all migrate.
2. Add a one-time migration note if `schema_version` increases in 2.0 (currently still 1).
3. Keep the "deprecated but retained" policy for any renamed keys through the 2.x line.

## Verdict

Config/data migration is **well-designed and forward-compatible (verified)**. The packaged
cross-version upgrade matrix is the one env-limited gap and is a pre-GA checklist item, not a code
defect.
