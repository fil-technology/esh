# esh — Embedded GGUF on iOS: Real-Device Benchmark (M7)

Proves GGUF runs **fully in-process** on a real iPhone through the public `EshRuntime` SDK:

```
EshIOSProbe → EshRuntime → InferenceBackendRegistry → LlamaCppEmbeddedBackend → llama.cpp (Metal) → GGUF
```

No `Process`, no localhost server, no Python. All numbers below are **measured on device** (from the probe's
`ESH-M7` log); nothing is estimated in the Measured section.

---

## 1. Measured device results

### Environment
| | |
|---|---|
| llama.cpp commit | **`4a89937354190cef5a97baf8eeb17336105eb72d`** (`ggml-org/llama.cpp`, MIT) |
| Build | `build-xcframework.sh` → `llama.xcframework` (macOS + iOS device + iOS-sim), Metal embedded (`GGML_METAL_EMBED_LIBRARY=ON`) |
| GGUF file | **`Qwen2.5-1.5B-Instruct-Q4_K_M.gguf`** (`bartowski/Qwen2.5-1.5B-Instruct-GGUF`) |
| GGUF license / size | **Apache-2.0** / **986,048,768 B (940.4 MB)** |
| GGUF SHA-256 | `1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370` |
| Device | **iPhone 17 (`iPhone18,3`)** |
| iOS | **26.6.2 (build 23G90)** |
| Physical memory | 8,044,216,320 B (7.49 GiB) |
| Thermal / Low-Power (during run) | **nominal / false** |
| Metal | **confirmed** — GPU offload active; `ggml_metal_free: deallocating` on unload |

### Load, generation, lifecycle
| Metric | Measured |
|---|---|
| **EshRuntime cold path** (pinned GGUF: first load + 16-tok gen, first-ever from disk) | **19.08 s** → output `"Pong"`, backend `gguf`, reason `explicit model pin` |
| **Warm load** (reload, OS file cache hot) | **0.22 s** |
| **Warm gen #1** (11 tok) | TTFT **89.9 ms**, **37.7 tok/s** — "The primary colors are red, blue, and yellow." |
| **Warm gen #2** (7 tok) | TTFT **70.7 ms**, **34.3 tok/s** — "Red, blue, and yellow." |
| **Process-available memory (`os_proc_available_memory`)** | **before GGUF: 3358 MB** → after load ≈ **3094 MB** → during gen ≈ **3091 MB** → end of suite ≈ **3007 MB** |
| **Unload recovery** | 3097 → 3196 MB (**~98 MB** compute/Metal buffers released) |
| **Reload after unload** | **0.21 s** (runtime immediately usable again) |
| **Cancellation** | mid-stream cancel **stopped** a 4096-token generation early (whole suite finished in ~60 s; the essay gen would have taken ~100 s otherwise); **`reuseAfterCancel = true`** — runtime remained usable. At the backend-runtime level cancel surfaces as a clean stream-finish (not a thrown error); the `EshRuntime` facade adds the thrown-`CancellationError` semantics (unit-tested). |
| **Context scaling** (32-tok gens) | ctx **512: 49.4 tok/s** · **2048: 50.1 tok/s** · **4096: 50.0 tok/s** |

### Apple Foundation Models — same device, same run (baseline)
| Metric | Apple FM | Embedded GGUF (Qwen2.5-1.5B Q4_K_M) |
|---|---|---|
| First call | **1.42 s** (TTFT 1418 ms) | 19.08 s first-ever load+gen; **0.2 s** warm reload |
| Warm call | **0.18 s** (TTFT 182 ms) | ~0.2–0.3 s (short gens) |
| Throughput | not exposed | **~35–50 tok/s** |
| Storage cost | **0 MB** (system model) | **940 MB** model file |
| App-size cost | **0 MB** | **~18 MB** (see below) |
| Availability | requires Apple Intelligence eligibility/enabled | runs on any device with enough memory |

### App binary-size delta
Release, iOS-Simulator (universal arm64 + x86_64), unsigned:
- **WITHOUT** the GGUF backend: **47 MB** `.app` (note: inflated by `swift-syntax`, which EshCore still links)
- **WITH** the GGUF backend: **65 MB** `.app`
- **Delta from llama.cpp + ggml + embedded Metal ≈ 18 MB** (universal-sim). A **device arm64-only** build carries a single slice, so the shipped-device contribution is roughly **~9 MB**.

### Regression (unchanged by M7)
macOS `swift test`: **641/641**. iOS-Simulator build of `EshCore` and `EshRuntime`: **green**. Apple FM path
still works (table above). No subprocess exists in the iOS GGUF path.

---

## 2. Interpretation

- **It works, in-process, on real hardware, through the public SDK.** The full lifecycle — cold load,
  warm generation, cancellation, unload, reload, and context scaling — ran without a crash, and the runtime
  stayed usable after both cancellation and unload.
- **Memory (read carefully).** The naive before/after "delta" (~94–98 MB) is **not** the model's memory
  footprint. The 940 MB weights are **mmap/file-backed** and paged lazily; Metal keeps its own mappings; and
  `os_proc_available_memory()` reports **process headroom before jetsam**, not RSS. The honest statement is:
  with the 1.5B Q4 model resident, the process still had **~3.0–3.1 GB of headroom** on this 8 GB device —
  i.e. **viable with comfortable margin** — while the **model file is 940 MB on disk**. Do not read the ~100 MB
  delta as the model footprint.
- **Speed.** Warm decode is **~35–50 tok/s** with sub-100 ms TTFT once loaded — genuinely usable for short
  interactive replies. But the **first-ever load is ~19 s** (cold mmap + Metal first-run); warm reloads are
  ~0.2 s. First-launch cost is real and must be surfaced in any UX.
- **vs Apple FM.** On this device Apple FM is **~1.4 s cold / 0.18 s warm, zero storage, zero app-size, no
  model management**, and produced equivalent answers for these simple prompts. Embedded GGUF costs 940 MB of
  storage, ~9–18 MB of app size, a ~19 s first load, and battery/thermal for sustained decode. **GGUF's value
  is not speed or convenience** — it is *controllable model choice, offline independence from Apple Intelligence
  eligibility, and specific models/behaviors Apple FM can't provide.*
- **Thermal/battery.** This was a short run at **nominal** thermal state; sustained/long-context decode will
  heat the device and draw battery. Not characterized here beyond "nominal during a short benchmark."

---

## 3. Future recommendations

- **Keep `Auto` Apple-first.** Nothing in this data justifies preferring a 940 MB downloaded 1.5B model over
  the zero-cost, faster-to-first-token system model on an eligible device.
- **Keep GGUF strictly explicit opt-in** (pin the model id), gated by the M5 `DeviceProfile` so a model that
  doesn't fit the measured headroom is refused rather than forced.
- **Recommended model-size class for ~8 GB iPhones: 1–2B Q4** (1.5B proven comfortable). 0.5–1B for the
  smallest/fastest; 3B is experiment-only; ≥4B not recommended.
- **Surface first-load cost** (~19 s) in any real UX (progress + "keep app foreground"); cache/warm where
  possible.
- **Next:** model *management* (sandbox download with size preflight via `DeviceProfile`, integrity
  verification, resumable) + wiring GGUF as an opt-in choice in a real app flow — **not** an `Auto` change.
  Consider the deferred `EshMacRuntime`/`swift-syntax`-out-of-core cleanup to shrink the iOS baseline (47 MB).

---

*Reproduce:* `scripts/build-llama-xcframework.sh` (pins the commit) → build `Examples/EshIOSProbe` for the
device → `devicectl device copy to … Documents/<gguf>` → launch; the app auto-runs the benchmark and writes
`Documents/esh-m7.log` (also `ESH-M7` to stdout). Raw device log retained with this milestone's evidence.
