# esh — Embedded GGUF / llama.cpp on iOS: Evaluation (M6)

**Status:** Evaluation / research only. **No production code, no `Package.swift` dependency, no
`LlamaCppEmbeddedBackend`.** This document is the decision input for the M7 implementation.
**Date:** 2026-09-13 · **Toolchain observed:** Xcode 26.6, cmake 4.4.2, Swift 6.
**Hardware baseline (measured, M5):** iPhone 17 (`iPhone18,3`), iOS 26.6.2 — physical **7.49 GiB**,
process-available **3.28 GiB** (`os_proc_available_memory`), storage **56.98 GiB**, thermal nominal.

Goal: run **GGUF models fully in-process on iOS** behind the existing `InferenceBackend` → `BackendRuntime`
contracts, never `Process → llama-server`.

---

## 1. Executive recommendation

**Adopt upstream `ggml-org/llama.cpp`, built into a pinned `llama.xcframework` via the project's official
`build-xcframework.sh`, vendored as a SwiftPM `binaryTarget`, and wrapped by a thin first-party esh target
(`EshLlamaCpp` / `LlamaCppEmbeddedBackend`) that implements the existing `InferenceBackend` /
`BackendRuntime` contracts.** Use **`mattt/llama.swift`** (an SPM package that re-exports the *same* official
upstream xcframework with semantic versioning) as the fallback/accelerator if self-hosting the binary proves
annoying to maintain.

Why: it is the authoritative source (MIT, updated the day of this evaluation), the only path upstream now
officially supports for Apple platforms, gives esh full control over streaming/cancellation/KV/unload/memory
(which the existing contracts require), and pins an exact commit for reproducibility. Convenience wrappers add
an API layer esh does not need and would couple us to a third party's release cadence.

**Verified locally:** `build-xcframework.sh ios-sim` compiles ggml (base/cpu/metal) + llama for the iOS
Simulator (arm64 + x86_64) and assembles `llama.xcframework` — **exit 0** on Xcode 26.6 / cmake 4.4.2.

---

## 2. Candidates evaluated

| # | Candidate | What it is |
|---|---|---|
| A | **Upstream `ggml-org/llama.cpp` + `build-xcframework.sh` (self-hosted xcframework)** | Official source; official Apple build script → `llama.xcframework`. esh pins a commit, builds, vendors the binary, writes its own Swift wrapper. |
| B | **`mattt/llama.swift`** | SPM package re-exporting the **official upstream xcframework** with semver; auto-tracks upstream releases. |
| C | **SpeziLLM / SpeziLLMLocal** (Stanford Spezi) | Higher-level local-LLM package; compiles llama.cpp to an xcframework binaryTarget. Opinionated; pulls the Spezi ecosystem. |
| D | Convenience wrappers — `ShenghaiWang/SwiftLlama`, `pgorzelany/swift-llama-cpp`, `PikaEarth/llama-cpp-swift` | Third-party Swift wrappers around llama.cpp with their own APIs (streaming, pinned xcframeworks, etc.). |
| — | ~~`alexrozanski/llama.swift`~~ | Old fork; superseded. Rejected. |
| — | ~~llama.cpp root `Package.swift` (SPM)~~ | **Removed upstream** — confirmed absent in the current tree. No longer a path. |

### Per-candidate evidence

**A — Upstream + self-hosted xcframework (RECOMMENDED)**
- Repo/maintenance: `github.com/ggml-org/llama.cpp`; HEAD `4a89937` dated **2026-09-13** (this evaluation's date) — extremely active, many commits/day.
- Upstream relationship: *is* upstream.
- iOS device + Simulator: `build-xcframework.sh` targets `ios-device` (Release-iphoneos) and `ios-sim`; **Simulator build verified locally (exit 0)**.
- Apple Silicon / Metal: `GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON` (metallib embedded in the static lib — no loose resource to ship), links `Metal.framework`.
- Min iOS / Xcode: `IOS_MIN_OS_VERSION=16.4`; builds under Xcode 26.6. (esh's Apple-FM path already needs iOS 26; 16.4 is comfortably below.)
- SwiftPM: no upstream SPM manifest anymore — integrate the produced `llama.xcframework` as a `binaryTarget`.
- Integration: XCFramework (device + sim + macOS + visionOS + tvOS slices) or a device+sim subset.
- Binary size: see §5.
- License: **MIT** (`Copyright 2023-2026 The ggml authors`).
- API stability: C API in `include/llama.h` is broad but has churned historically; **pinning a commit** neutralizes this. Reference wrapper: `examples/llama.swiftui` + `examples/llama.cpp.swift`.
- Streaming / cancellation / KV / unload / memory: all first-class via the C API (§4).
- Implements esh contracts cleanly: **yes** (§4).

**B — `mattt/llama.swift`**
- SPM package that re-exports the official upstream xcframework, semver, "stays current with upstream". Same binary as (A) with less build machinery for esh to own.
- Trade-off vs (A): less control over exactly which commit/config; depends on the package author's cadence. Good fallback; also a fast way to prototype M7 before deciding to self-host.
- License: MIT (wrapper) over MIT (llama.cpp).

**C — SpeziLLM / SpeziLLMLocal**
- Maintained (Stanford Biodesign Digital Health), xcframework binaryTarget, semver. But it is a *local-LLM app framework*, not a thin binding — adopting it would duplicate/conflict with esh's own `EshRuntime`/router/Model-Fit and pull the Spezi ecosystem. **Rejected for esh** (right idea, wrong altitude).

**D — SwiftLlama / swift-llama-cpp / llama-cpp-swift**
- Useful references (e.g. `llama-cpp-swift` does streaming via structured concurrency; `swift-llama-cpp` pins an xcframework). But each imposes its own API and maintenance risk, and esh already owns the backend contract. **Rejected as a dependency**, kept as design references. `llama-cpp-swift` is macOS/Linux-focused (weaker iOS story).

---

## 3. License & maintenance conclusion

llama.cpp is **MIT** — compatible with esh, no copyleft, redistribution of a built xcframework is fine with
attribution. Maintenance is excellent (daily upstream activity). **Risk to manage:** API churn — mitigated by
pinning an exact upstream commit and re-building deliberately, exactly as esh already pins other deps.

---

## 4. Mapping to esh's `InferenceBackend` / `BackendRuntime`

The `include/llama.h` C API covers every method the contracts need (symbols verified in the clone):

| esh contract need | llama.cpp C API |
|---|---|
| Load model (BackendRuntime creation) | `llama_model_load_from_file`, `llama_init_from_model` |
| Chat formatting | `llama_chat_apply_template`, `llama_chat_builtin_templates` |
| Generate **token stream** (`AsyncThrowingStream<String>`) | loop: `llama_decode` + `llama_sampler_sample` + `llama_token_to_piece` |
| **Cancellation** | cooperative — we drive the decode loop, so check `Task.isCancelled` between tokens (clean, immediate) |
| **KV / context control** | `llama_n_ctx`, `llama_memory_clear`, `llama_state_get_size` |
| **Unload** (`BackendRuntime.unload()`) | `llama_free` (context) + `llama_model_free` (weights) |
| **Memory accounting** | `llama_model_size` + M5 `os_proc_available_memory()` before/after |

Swift 6 concurrency: llama.cpp is synchronous C; esh wraps a context in an **actor** (serialize model access),
runs `llama_decode` on a dedicated executor/queue, and bridges tokens into `AsyncThrowingStream` — the same
shape `AppleBackendRuntime` already uses. No `@unchecked Sendable` leakage beyond an opaque context handle.

---

## 5. Binary-size implications

Measured from the local `ios-sim` build (**unstripped Release static archives, universal arm64+x86_64**):

| Archive | Size |
|---|---|
| `libllama.a` | 146 MB |
| `libggml-base.a` | 12 MB |
| `libggml-cpu.a` | 8.5 MB |
| `libggml-metal.a` | 7.6 MB |
| `libggml.a` | 1.5 MB |
| `llama.xcframework` (ios-sim slice only, on disk) | 134 MB |

**These are pre-link archives with debug symbols and are NOT the app-size cost.** After linking one
architecture, dead-stripping, and Release symbol handling, the contribution to a shipped **arm64 device**
binary is far smaller (llama+ggml is a compact C/C++ core; the embedded metallib adds ~1–2 MB). A precise
number requires linking it into an app and measuring the Release device binary + `.ipa` — **that is an M7
deliverable**, not a README claim. The distributable xcframework (all slices, unstripped) is large and should
be trimmed to device+sim and stripped for distribution.

---

## 6. Model viability matrix — measured iPhone 17 (~8 GB, 3.28 GiB process headroom)

**Do not read 7.49 GiB as usable.** The binding constraint is **process/jetsam headroom** (~3.28 GiB measured
here) shared with the app UI, minus a thermal/safety margin. Conservative budget for the model runtime:
**~2.3–2.5 GiB** (leaving ~0.8–1.0 GiB for the app + jetsam margin). Runtime memory ≈ quantized weights
(Q4_K_M) + KV cache + compute/Metal buffers + overhead.

| Class | Q4_K_M weights (approx) | Est. runtime @ 2–4k ctx | Verdict on this device |
|---|---|---|---|
| **sub-1B** (e.g. 0.5B) | ~0.4 GB | ~0.7–1.0 GB | **comfortable** |
| **~1B–2B** | ~0.8–1.3 GB | ~1.2–1.8 GB | **comfortable → plausible** (sweet spot) |
| **~3B** | ~1.9–2.2 GB | ~2.3–2.7 GB | **tight / experiment only** (near headroom; risky with UI + thermal) |
| **~4B** | ~2.4–2.8 GB | ~2.9–3.4 GB | **not recommended** (meets/exceeds headroom → jetsam risk) |
| **7B+** | ~4.5 GB+ | ~5 GB+ | **not recommended** (far exceeds headroom) |

Assumptions: Q4_K_M quantization; context 2–4k; Metal on; single active model; foreground app. Larger context,
higher precision, or background pressure shift every row worse. Thermal `serious`/`critical` or Low Power Mode
(surfaced by the M5 `DeviceProfile`) should push selection down a row or defer.

**Sweet spot on an ~8 GB iPhone: ~1B–2B Q4.** Smallest useful: ~0.5B. 3B is experiment-only; ≥4B is off the
table on this device class.

---

## 7. Recommended first GGUF models for the M7 benchmark

Small, modern, instruct-tuned, permissive where possible (not a catalog — enough to answer the key questions):

| Model | Size | License | Role |
|---|---|---|---|
| **Qwen2.5-0.5B-Instruct** (Q4_K_M) | 0.5B | Apache-2.0 | smallest useful; "does tiny work at all?" |
| **Qwen2.5-1.5B-Instruct** (Q4_K_M) | 1.5B | Apache-2.0 | **primary sweet-spot candidate** |
| **SmolLM2-1.7B-Instruct** (Q4_K_M) | 1.7B | Apache-2.0 | sweet-spot alternative, clean license |
| **Llama-3.2-1B-Instruct** (Q4_K_M) | 1B | Llama 3.2 Community | capability comparison at 1B |
| **Llama-3.2-3B-Instruct** (Q4_K_M) | 3B | Llama 3.2 Community | the "tight" boundary — where jetsam/thermal bite |

Apache-2.0 models are preferred defaults (fully permissive); the Llama-licensed ones are for capability
comparison and carry acceptable-use terms to record. This set answers: smallest useful (0.5B), sweet spot
(1.5–1.7B), and where the device breaks down (3B).

---

## 8. M7 benchmark plan (reproducible)

Run through the **`EshRuntime` public API** (via `LlamaCppEmbeddedBackend`), on the physical iPhone 17, using
the existing `EshIOSProbe` app host pattern. For each model × {context 512, 2k, 4k}:

- **cold model load** time; **warm generation** latency; **TTFT**; **tokens/sec** (decode).
- **peak process memory**; **`os_proc_available_memory()` before / during / after** (M5 signal).
- **model unload + recovery** (memory returns; a second load succeeds).
- **cancellation** (mid-decode `Task.cancel()` stops promptly, frees memory).
- **context scaling** (latency/memory vs context length).
- **thermal-state changes** and **Low Power Mode** behavior (via M5 `RuntimePressureSource`).
- **repeated prompts** (stability, no leak/drift over N runs).
- **app background/foreground** (does the runtime survive / release correctly?).
- **Apple FM comparison** — same prompts through the existing `AppleBackend` for latency/quality/memory.

Deterministic parts run in a harness; live model runs stay off ordinary CI (no model downloads in CI).

**The central M7 question — Apple FM as the baseline:** does an embedded downloaded GGUF model provide enough
capability / control / offline / privacy benefit to justify its memory, storage, battery, and thermal cost
**versus the zero-download on-device Apple Foundation Models** esh already ships? On an 8 GB iPhone where the
sweet spot is 1–2B, the bar is high: embedded GGUF must earn its place (e.g. specific models/control Apple FM
can't provide), not merely duplicate it.

---

## 9. Rejected alternatives

- **`Process → llama-server` on iOS** — impossible/forbidden (no subprocess on iOS); the entire reason for an
  in-process backend. This stays the **macOS-only** path (M1 kept it behind `#if os(macOS)`).
- **llama.cpp root SwiftPM package** — removed upstream; not available.
- **SpeziLLM** — too high-altitude; would duplicate `EshRuntime`/router/Model-Fit and pull an ecosystem.
- **Convenience wrappers (SwiftLlama, swift-llama-cpp, llama-cpp-swift)** — unnecessary API layer + third-party
  maintenance risk when esh already owns the backend contract; kept only as design references.
- **Native MLX on iOS** — out of scope for the GGUF question (separate future track; also a stated exclusion).

---

## 10. Unresolved risks

1. **Real device memory ceiling** — the 3.28 GiB headroom is one measurement; jetsam limits vary with device
   state and OS. M7 must measure peak memory + available-memory under load on-device, not estimate.
2. **App-size cost** — must be measured from a linked, stripped Release device build (not the 134 MB archive).
3. **API churn** — pin a commit; budget periodic re-pin + re-test.
4. **Metal on-device vs Simulator** — Simulator build is verified; **device** Metal execution + performance is
   unverified until M7 (Simulator does not represent device GPU/thermal).
5. **Thermal/battery under sustained decode** — small models still heat an iPhone; M7 must characterize.
6. **Value vs Apple FM** — embedded GGUF may not justify its cost on this device class; M7 must decide honestly.
7. **Distribution** — shipping/downloading the xcframework vs the model weights; storage-aware download (M5
   storage signal) and model integrity verification are M7 concerns.

---

## 11. Recommended exact M7 scope

1. Pin an upstream `ggml-org/llama.cpp` commit; add a script to build a **device+sim** `llama.xcframework`
   (Metal embedded, stripped Release); record the pinned commit + build steps. Vendor as a SwiftPM
   `binaryTarget` in a **new `EshLlamaCpp` target** (iOS+macOS), isolated from `EshCore`.
2. Implement **`LlamaCppEmbeddedBackend: InferenceBackend`** + its `BackendRuntime` (actor-wrapped context):
   load/stream/cancel/unload/KV-clear/memory-report per §4. No subprocess, no server, no Python.
3. Wire it into the platform assembly as an **additional** iOS backend candidate (behind explicit opt-in /
   pinning first); Auto continues to prefer Apple FM until benchmarks justify otherwise. Reuse M5 `DeviceProfile`
   for fit (block/deny models that don't fit the measured headroom).
4. Model storage: app-sandbox download with size preflight (M5 storage), resumable + integrity-verified; no
   invisible large downloads. Start with **Qwen2.5-1.5B-Instruct Q4_K_M**.
5. Execute the §8 benchmark on the iPhone 17; write `docs/IOS_EMBEDDED_GGUF_BENCHMARK.md`; measure real
   app-size delta. Then decide Auto-selection policy vs Apple FM.

**Explicit M7 boundary:** in-process only —
`EshRuntime → existing router/Model-Fit → LlamaCppEmbeddedBackend → in-process llama.cpp → GGUF`. Never
`Process → llama-server` on iOS. No changes to Apple FM behavior; no `EshMacRuntime` cleanup bundled in.

---

*Sources:* upstream `github.com/ggml-org/llama.cpp` (cloned & inspected: `build-xcframework.sh`, `include/llama.h`,
`LICENSE`, `examples/llama.swiftui`; `ios-sim` build verified locally, exit 0); `github.com/mattt/llama.swift`;
`github.com/StanfordSpezi/SpeziLLM`; `github.com/ShenghaiWang/SwiftLlama`; `github.com/pgorzelany/swift-llama-cpp`;
`github.com/PikaEarth/llama-cpp-swift`. Hardware baseline: esh M5 `docs/IOS_APPLE_FM_DEVICE_VALIDATION.md`.
