# esh Stabilization — Phase 0 Baseline & Repository Truth Audit

_Audited from actual code, build, tests, and live HuggingFace metadata on 2026-08-31.
Repository: https://github.com/fil-technology/esh — audited at `main` (VERSION `0.1.41`),
work continues on branch `codex/esh-stabilization`._

This document is the ground truth for the stabilization program. Every later phase is
grounded in what is written here, not in the README/planning notes. Where the spec
(ClickUp 86eyt8ubw) assumes something that does not match the code, it is called out under
**Spec deltas**.

---

## 0. Verified command / build matrix

| Check | Command | Result |
|---|---|---|
| Toolchain | `swift --version` | Apple Swift 6.3.3, target arm64-apple-macosx26.0, Xcode at `/Applications/Xcode.app` |
| Build | `swift build` | ✅ exit 0 (clean) |
| Tests | `swift test` | ✅ **130 tests / 25 suites, 0 failures, ~16s** (swift-testing framework) |
| Package manifest | `Package.swift` | swift-tools 6.0, `platforms: [.macOS(.v14)]` |

The build and full unit-test suite are **green at baseline.** No compile or test failures.
There is an acknowledged residual: Swift concurrency warnings from `ProcessRunner.swift`
(README ~610). Tests are pure-Swift + mocked network; **no test downloads a real model or
runs real MLX/llama.cpp/TTS inference** (see §8).

### CLI surface (from `Sources/esh/main.swift`)
Top-level verbs: `chat`, `model`, `audio`, `session`, `cache`, `agent`, `calibrate`,
`context`, `run`, `routing`, `infer`, `serve`, `integrations`, `launch`, `read`, `config`,
`engines`, `validate`, `doctor`, `capabilities`, `benchmark`, `version`, `update`.
`model` subverbs: `recommended | list | search | check | install | open | inspect | remove`.
Running `esh` with a TTY shows an interactive menu; **there is no `onboard` or `storage`
verb today** (see §6, §3).

---

## 1. Architecture map (as built)

```
Sources/
  EshCore/               (library — the runtime/intelligence engine)
    Backends/MLX/        MLX via out-of-process Python bridge (Tools/mlx_vlm_bridge.py)
    Backends/GGUF/       llama.cpp via `llama-cli` subprocess
    Compression/TurboQuant/  KV-cache quant (TurboQuant / TriAttention)
    Downloads/           Pure-URLSession HuggingFace downloader + resume
    Persistence/         File-backed stores rooted at PersistenceRoot (~/.esh)
    Services/            Model catalog, install preflight, OpenAI/Anthropic services,
                         routing, context engine, orchestrator, config store
    Protocols/ Domain/ Utils/
  esh/                   (executable — CLI/TUI, HTTP server controller, commands)
Tools/                   mlx_vlm_bridge.py, triattention_runtime.py, python-requirements.txt
scripts/                 package-release, sign, notarize, homebrew cask, bootstrap, smoke
Tests/                   EshCoreTests (29), EshUITests (4), Python (1), Fixtures
```

- **Backends are subprocess-based.** MLX shells out to a bundled/venv Python running
  `Tools/mlx_vlm_bridge.py` (JSON over stdin/stdout; `mlx-generate` streams tokens line by
  line). GGUF shells out to `llama-cli`. TTS is the **only** in-process MLX/Metal path (via
  the `TTSMLX` Swift package).
- **One HTTP server** (`OpenAICompatibleLocalServer`, a hand-rolled `NWListener` HTTP/1.1
  server) hosts both the OpenAI and Anthropic handlers.

---

## 2. Storage architecture **today** (critical for Phase 2)

### The one real abstraction: `PersistenceRoot` (`Persistence/PersistenceRoot.swift`)
- Root = `ESH_HOME` → `LLMCACHE_HOME` → else `~/.esh`. Legacy `~/.llmcache` is auto-migrated
  (move → copy → merge) on first run.
- Exposes only **4** sub-URLs: `sessions/`, `caches/`, `models/`, `benchmarks/`.

### But the real `~/.esh` on disk has ~12 subdirs
`context/ runtime/ models/ audio/ sessions/ benchmarks/ compression/ external/ runs/
metadata/ context-packages/ caches/` — i.e. **most large/stateful paths are constructed
outside `PersistenceRoot`**, by each store/service. This is the core Phase 2 problem: there
is no central storage abstraction, and no notion of "internal config vs external large
assets."

### Where large assets actually live (file:line)
| Asset | Location | Constructed by |
|---|---|---|
| Model weights (MLX/GGUF) | `~/.esh/models/installs/<id>/` | `FileModelStore` (root.modelsURL) |
| Model manifests | `~/.esh/models/manifests/<id>.json` | `FileModelStore` |
| Prompt/KV caches | `~/.esh/caches/{manifests,payloads}/` | `FileCacheStore` |
| Python venv runtime | `~/.esh/runtime/python/` | `PackagedRuntimeBootstrap.swift:48` |
| **TTS voice weights** | **`<CWD>/.esh/tts-models/`** ⚠️ | `AudioSpeechGenerator.swift:45` |
| **Generated audio** | **`<CWD>/.esh/audio/`** ⚠️ | `AudioCommand.swift:80`, `main.swift:616` |
| MLX runtime state json | `NSTemporaryDirectory()/esh-runtime-*.json` | `MLXRuntime.swift:15` |
| MLX metallib build cache | `<CWD>/.build/esh-metal` | `AudioSpeechGenerator.swift:161` |

### Storage findings / risks
1. **⚠️ TTS models and audio output are CWD-relative** (`<current dir>/.esh/...`), not
   `~/.esh`. Running `esh audio ...` from different directories creates **duplicate
   multi-GB TTS caches** and scatters output. This is a real bug and a Phase 2 blocker.
2. **`model_dir` config is dead.** `EshConfig.defaults.modelDir` (default `~/.esh/models`)
   is **never read anywhere outside `EshConfig.swift`** (verified by grep). The only way to
   relocate models today is `ESH_HOME`, which moves **everything** (config + state + models
   + venv) together — the opposite of the spec's "light config internal / heavy assets
   external" split.
3. **No external-volume awareness.** No availability check, no "volume unavailable" error,
   no free-space gate at the storage layer (only `ModelInstallPreflightService` checks free
   space, at install time, against the internal root).
4. **Tilde expansion is re-implemented ≥3×** (`EngineOrchestratorService:244`,
   `LocalModelValidationService:97`, `ValidateCommand:85`) — no shared path utility.
5. `SystemStorage.snapshot(at:)` already reports free bytes **for any URL** (works for
   external volumes) — a good building block to reuse in Phase 2.

---

## 3. Model install / download reliability today (Phase 4)

Downloader is **pure Swift URLSession** (no `huggingface_hub`, no git, no `hf` CLI):
- Metadata: `GET huggingface.co/api/models/<repo>`; files: `GET .../resolve/<rev>/<path>`
  streamed in 64 KB chunks to a `FileHandle`.
- **Resumable: yes** — `Range: bytes=<existing>-`, handles 206/200, restarts on 416.
- **No `.partial` staging, no atomic completion marker.** Bytes append directly to the final
  filename. A model counts as "installed" **only once the manifest JSON is written** (after
  download + verify), so a SIGKILL mid-download leaves **orphan payload bytes with no
  manifest** (not shown as installed, but silently resumed / never cleaned).
- **Verification is byte-count only** (HF-reported size == on-disk size). **No checksum** —
  a corrupt-but-right-length file passes.
- On any thrown error the whole `installs/<id>/` dir is deleted (clean). Only hard-kill
  leaves orphans.
- **No import-without-download and no external scan.** `ModelSource.Kind.localPath` exists
  but is used only by `model open`, never `install`. `HF_HOME` / `HUGGINGFACE_HUB_CACHE`
  are **not** reused. `LocalModelCatalog` only lists already-manifested installs.

---

## 4. Model catalog state (Phase 3)

`RecommendedModelRegistry.defaultModels` = **26 entries** (19 MLX + 7 GGUF), plus hardcoded
starter ID lists in `main.swift:520`.

**All 26 repos are REAL and current** — verified against live HF metadata. (Several use
model families newer than this engine's Jan-2026 model knowledge — e.g. `Qwen3.5-*`,
`gemma-4-e{2,4}b`, `Qwen3.5-*-OptiQ`, `Qwen3.5-27B-Claude-4.6-Opus-Distilled` — all resolve
with real weights and thousands of downloads; a non-existent control repo returns HTTP 401.)
**Do not "remove hallucinated models" — they exist.** The real Phase 3 work is metadata and
compatibility, not deletion.

### Catalog gaps vs the spec
- **`RecommendedModel` is metadata-thin.** It has: id, title, repoID, parameterSize,
  quantization, `profile` (only `.chat`/`.code`), `tier` (good/small/tiny/max — size-based,
  confusingly named, e.g. "Max (Pushing 32GB Mac Limits)"), memory/disk GB, freeform `tags`,
  summary, backend. **Missing:** context window, structured capabilities (chat / coding /
  reasoning / tool-calling / vision), chat-template / tool-schema requirements, and a
  `status` (recommended / experimental / legacy / incompatible).
- **No validation that a catalog entry's runtime template/tool schema actually works** — the
  exact failure mode the spec warns about ("installs but fails").
- Profiles requested by spec (fast / balanced / best-for-this-Mac / coding / reasoning /
  low-memory) are only partially expressible via `profile`+`tier`+`tags`.
- Catalog is a **hardcoded Swift array**, not data-driven (spec wants "data-driven, easy to
  update").

---

## 5. Config state (Phase 7)

- File: `~/.esh/config.toml` (`EshConfigStore`, root from `PersistenceRoot`).
- Parser: **hand-rolled line-by-line TOML** in `EshConfig.swift` (not a real TOML lib;
  silently ignores unknown keys/malformed lines). Sections: `[defaults]`
  (engine, model_dir, context_size), `[engines.llama_cpp]`, `[engines.mlx]`,
  `[experimental]`.
- `esh config` supports only `init [--force] | show | path` — **no `set`.**
- **No schema/config version field** (spec wants explicit versioning + migration).
- **Two conflicting sources of truth for "where models live":** `EshConfig.defaults.modelDir`
  (dead) vs `PersistenceRoot` (real). Runtime binary/python paths are resolved from env in
  `scripts/lib/common.sh` + `RuntimePathResolver`, largely independent of config values.
- **No config round-trip / migration / env-precedence tests.**

---

## 6. Onboarding state (Phase 5)

- **There is no onboarding flow and no `esh onboard` command.** First-run behavior is:
  `esh` (with a TTY) → `showDefaultMenu()` → if 0 models installed, `showStarterModelsMenu()`
  offers a hardcoded starter list (`main.swift:520`), MLX or GGUF, install-one-and-return.
- No hardware/RAM/disk-aware recommendation at first run (though
  `HostMachineProfileService` already computes chip + RAM + a `safeBudgetGB` and could feed
  it). No storage-location choice. No existing-model detection beyond "count installs". No
  validation inference. No persisted onboarding state/version.
- `starterModels()` in `main.swift:520` references IDs (`qwen-2-5-0-5b`, `llama-3-2-3b`,
  `qwen-2-5-coder-7b`, `mistral-small-24b`, `qwen-3-5-9b-optiq`, and GGUF variants) that must
  stay in sync with the registry by hand — brittle.

---

## 7. Runtime surface: serve / infer / doctor / TTS

### `esh serve` HTTP routes (OpenAI handler; `OpenAICompatibleHTTPHandler.swift`)
`OPTIONS *` (CORS), `GET /` `GET /health` `GET /v1` (status), `GET /v1/models`,
`GET /v1/audio/models`, `POST /v1/audio/speech` (WAV only), `GET /v1/tools` (**stub → []**),
`GET /api/tags` (Ollama-compat), `POST /v1/chat/completions`, `POST /v1/responses`. Bearer
auth when a key is configured.

- **⚠️ "Streaming" is buffered, not incremental.** Every SSE route runs full non-streaming
  inference, then slices the finished text into SSE chunks and returns the whole body with a
  fixed `content-length` and `connection: close` — clients get all events at once.
- **The Anthropic surface (`/v1/messages`) exists and works but is NOT reachable via
  `esh serve`** — only through `esh integrations serve` (Claude Code integration). Spec/README
  mention an "Anthropic surface if present"; it is present but gated.
- `response_format: json_schema` is parsed but rejected ("MLX constrained decoding
  required"); tool messages unsupported.

### `esh infer`
Single JSON blob to stdout (no CLI token streaming), via the same `ExternalInferenceService`
the server uses; supports rich generation/KV-quant/thinking flags and optional routing.

### `esh doctor` (Phase 6)
Delegates to `EngineOrchestratorService.listEngines()`; checks 6 engines (llama.cpp + MLX
required; llamafile/ollama/transformers/llama-server optional, detection-only). Reports
python/mlx/mlx-lm/mlx-vlm/numpy/safetensors versions, `persistence_root`, `config` path.
**Plain text only — no JSON option** (spec wants stable JSON for Ashex). **Does NOT check:**
storage availability / free space, model corruption/incompleteness, **port conflicts**, TTS
readiness, HF reachability, or a real inference smoke test.

### TTS
`TTSMLX` Swift package, in-process MLX/Metal. Preflight (metallib compile + Metal device)
happens lazily at synthesis, not in doctor. `esh audio speak|models`; STT (`audio
transcribe`) is an explicit **"not wired yet"** stub.

---

## 8. Test gaps (Phase 8)

Covered: model catalog, download coordinator + HF downloader (mocked), install preflight,
OpenAI/Anthropic compat services, cache manifest, routing, agent loop, terminal surface,
TurboQuant, MLX bridge round-trip (via helper process).

**No coverage for:** `EshConfigStore` TOML round-trip / migration, `ESH_HOME`/`LLMCACHE_HOME`
precedence, `PersistenceRoot` legacy migration, `serve`/live HTTP routes, TTS/audio path,
external-storage connect/disconnect/reconnect, path-with-spaces, low-disk, partial-download
recovery, imported GGUF / imported MLX, backend-unavailable, release-package smoke (exists in
CI as a script, not a unit test).

---

## 9. Dependencies & packaging (Phase 1, 10)

### SwiftPM (from `Package.resolved`)
| Package | Resolved | Pin in Package.swift |
|---|---|---|
| swift-syntax (swiftlang) | 600.0.1 | `from: "600.0.1"` |
| TTSMLX (fil-technology) | 0.3.3 | `from: "0.3.3"` |
| mlx-audio-swift (Blaizzy) | rev `c96fe7b8…` (no tag) | exact revision |
| mlx-swift (ml-explore) | 0.31.3 | transitive |
| mlx-swift-lm | 2.31.3 | transitive |
| swift-transformers 1.2.1, swift-huggingface 0.9.0, swift-jinja 2.3.5 | | transitive |
| EventSource 1.4.1, yyjson 0.12.0, swift-nio 2.99.0, swift-crypto 4.5.0, … | | transitive |

**`EshCore` imports SwiftSyntax/SwiftParser** — audit in Phase 1 whether this is actually
used (symbol extraction / context engine) or a heavyweight dependency that can be dropped or
isolated. SwiftSyntax `600.x` tracks the toolchain; a 6.3 toolchain typically wants a newer
major — verify compatibility before bumping.

### Python (`Tools/python-requirements.txt`)
`mlx>=0.31.2`, `mlx-lm>=0.31.3`, `mlx-vlm==0.5.0`, `safetensors>=0.4,<1`. The bridge
hardcodes `MLX_VLM_PACKAGE_VERSION = "0.5.0"` and imports `mlx_vlm.turboquant`. Doctor reports
but does **not enforce** these pins.

### Packaging
- Self-contained macOS **tarball/zip** (not `.app`): `scripts/package-release.sh` →
  `swift build -c release`, bundles a **copied Python venv** (`python/`), `llama-cli`
  (`share/esh/bin/`), MLX `mlx.metallib`, bridge scripts, `share/esh/scripts/run.sh`, root
  `esh` launcher shim.
- Distribution: **Homebrew CASK** (`fil-technology/homebrew-tap`, `Casks/esh.rb`),
  `depends_on formula: python`, macOS `>= ventura`. Release workflow codesigns +
  notarizes + pushes to GHCR + updates the tap.
- CI (`.github/workflows/ci.yml`): single matrix, `macos-26`, Python 3.10 — runs
  `swift test`, `esh doctor`, `esh --help`, then a package smoke test. No multi-version
  matrix.

---

## 10. Docs vs reality (to fix as behavior lands)

| Claim | Reality |
|---|---|
| README:305 / README:343 / USAGE:209 — `esh model install fast-chat`, "built-in alias like `fast-chat`" | **No `fast-chat` alias exists** anywhere in code — this command fails. Stale. |
| README first-run downloads TTS into `.esh/tts-models` | True, but **CWD-relative**, not `~/.esh` (bug). |
| README "Esh stores data under `~/.esh`" | True for models/sessions/caches/benchmarks; **TTS + audio escape to CWD**. |
| README ~610 "some build runs still show Swift concurrency warnings from ProcessRunner.swift" | Acknowledged, unresolved. |
| `docs/USAGE.md` optional engines / README STT | Correctly documented as not-yet-wired (matches code). |
| Local `dist/esh-macos-20260512-221153/` bundle | Incomplete/stale **local, untracked** artifact (not in git) — ignore; not a valid release. |

---

## 11. Spec deltas (implement differently than the ClickUp bullets)

1. **Do not delete "hallucinated" models.** All 26 catalog repos are real (§4). Phase 3 =
   enrich metadata + compatibility validation + data-driven catalog, not pruning.
2. **Storage split can't rely on `model_dir`** — that knob is dead (§2.2). Phase 2 needs a new
   central `StorageLayout` abstraction that classifies paths (config/state internal vs
   models/caches/audio/tmp relocatable) and is threaded through the stores, plus a real
   config section (`[storage]`) with a schema version (folds into Phase 7).
3. **Fix CWD-relative TTS/audio first** (§2.1) — it undermines any external-storage story and
   is a prerequisite for Phase 2/5.
4. **`esh serve` should optionally expose the existing Anthropic surface** (it already exists,
   just ungated) rather than building a new one (§7).
5. **Streaming is buffered** (§7). True incremental streaming is a real improvement but is
   arguably esh-2.0 scope; for stabilization, at minimum make the server send chunked
   transfer so clients see events progressively — evaluate cost in Phase 9, don't rewrite the
   inference path.
6. **Doctor JSON** (Phase 6) and **storage doctor** (Phase 2) should share one machine-readable
   diagnostic model so Ashex has a single stable schema.

---

## 12. Recommended phase ordering (unchanged from spec, with dependencies)

Phase 1 (deps) can proceed independently. **Phase 2 (storage v2) is the keystone** — Phases
3–6 and onboarding all depend on a real storage abstraction, so it goes first among the
product phases, immediately after fixing the CWD-relative TTS/audio bug. Config/migration
(Phase 7) is co-designed with Phase 2 (the `[storage]` section + schema version). Onboarding
(Phase 5) is built last on top of stabilized storage + catalog + doctor, exactly as the spec
requires.

**Exit criteria for Phase 0 — met:**
- ✅ build/test baseline known (green: 130 tests).
- ✅ no hidden assumptions about model/storage locations (all mapped, §2).
- ✅ every following phase grounded in actual code (file:line references throughout).
