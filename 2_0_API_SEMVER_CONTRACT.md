# esh 2.0.0 — Public API & SemVer Contract (Phase Q)

**Date:** 2026-09-01

This defines what esh 2.0 promises to keep stable, so downstream users (scripts, editor integrations,
OpenAI-SDK clients) can rely on it. esh follows **Semantic Versioning** from 2.0.0: within the 2.x
line, no breaking changes to the **Stable** surfaces below; additions are minor, fixes are patch.

---

## 1. HTTP API (OpenAI-compatible) — STABLE

Verified routes served by `esh serve` / `esh web`:

| Method | Path | Stability |
|---|---|---|
| GET | `/health`, `/v1` | Stable — status + route list |
| GET | `/v1/models` | Stable — OpenAI models list shape |
| POST | `/v1/chat/completions` | **Stable** — OpenAI chat completions (streaming + non-streaming) |
| POST | `/v1/responses` | Stable — OpenAI Responses API (streaming + non-streaming) |
| GET | `/v1/tools` | Stable |
| GET | `/v1/audio/models` | Stable — advertised TTS models (broken models filtered) |
| POST | `/v1/audio/speech` | Stable — TTS (WAV) |
| POST | `/v1/audio/transcriptions` | **New in 2.0** — STT (JSON `{text}`) |
| GET | `/api/tags` | Stable — Ollama-compatible tag list |
| GET | `/web`, `/chat` | Stable route; the **HTML is not an API** (may change freely) |

**Compatibility promises (2.x):**
- Request/response field names and OpenAI-compatible semantics on the Stable routes will not change
  incompatibly. New optional request fields and new response fields may be **added**.
- The **capability-resolution contract** is stable: an unsupported option is always surfaced
  (`applied`/`approximated`/`rejected`/`ignored`) and never silently honored. `strict` structured
  output is rejected (not approximated) where native constrained decoding is unavailable.
- `monetaryCostUSD` for local inference stays `0` with on-device provenance.
- Loopback-by-default and the `--api-key` bearer scheme are stable.

**Explicitly NOT part of the API contract:** the Web Chat HTML/JS, exact `x-esh-*` header values,
log/stderr text, and internal reasoning/`[end of text]` stripping details.

---

## 2. CLI — STABLE command surface

Top-level commands (stable names & core flags): `agent, apple, audio, benchmark, cache, calibrate,
capabilities, chat, config, context, doctor, engines, infer, integrations, launch, model, onboard,
optimize, performance, read, routing, run, schedule, serve, session, storage, update, validate,
version`.

**Promises (2.x):**
- These command names and their documented core flags remain. New subcommands/flags may be added.
- `--json` outputs (e.g. `esh update check --json`, `esh schedule --json`, `esh doctor --json`) keep
  their existing keys; new keys may be added. Consumers must ignore unknown keys.
- Exit codes: `0` success, non-zero failure. Machine consumers should use `--json` where available
  rather than parsing human text.

**Not stable:** human-readable table/log formatting, ordering of non-`--json` output, progress text.

---

## 3. On-disk & config — STABLE with migration

- Model store layout under the configured storage root (default or `esh storage set`), manifests, and
  session/cache stores are stable within 2.x; any format change ships with a migration (Phase L).
- `EshConfig` (TOML) keys are stable; new keys (e.g. `tts_model`, `stt_model`) may be added and are
  optional with sensible defaults.

---

## 4. Model catalog — curated, versioned data (not code API)

The recommended-model catalog is **data**, not a stability contract: entries can be added, retired,
or reclassified (`recommended`/`experimental`/`legacy`/`incompatible`) as runtimes change. The
**guarantee** is behavioral: esh never recommends or defaults to a known-broken model, and never
silently substitutes one model for another.

---

## 5. Deprecation policy (2.x)

- A Stable surface slated for removal is **deprecated for at least one minor release** with a runtime
  notice before removal in a later minor.
- Breaking changes to Stable surfaces are reserved for **3.0**.

---

## 6. Version story note (audit A1)

`main` currently carries `VERSION=0.9.8` while the latest **published** release is `v0.9.7`; 0.9.8 was
never tagged. Before cutting `2.0.0-rc.1`, the version must roll to the 2.0 line and the intervening
work be captured in the changelog so the SemVer baseline is unambiguous. Tracked in Phase S.
