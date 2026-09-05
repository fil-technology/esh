# esh 2.1 — Image Editing & Artifact Transformation — PRODUCTION-READY

**Status (2026-09-05):** ✅ `image.edit` (image + instruction → image) is a first-class Universal Capability, live-qualified on Apple M1 Pro / 32 GB with a commercial-safe local model.

## Capability taxonomy
One canonical **`image.edit`** — the operation rides in the natural-language instruction (remove/replace/change/restyle/relight/…), NOT a fan-out of `image.inpaint`/`outpaint`/`restyle`. The Router reasons in user intent; the provider/bridge own model/runtime details. Backends are an internal detail (`qwen-edit` | `flux2-klein` | `kontext`), selectable via an option; not separate capabilities.

## Candidate research (Apple-Silicon, mflux)
| Model | Backend | License | 4-bit size | 32 GB fit | Verdict |
|---|---|---|---|---|---|
| **FLUX.2 Klein 4B** | `flux2-klein` | **Apache-2.0** ✅ | ~24 GB weights → **~5.2 GB peak at load-time q4** | **comfortable** | **QUALIFIED (default)** |
| Qwen-Image-Edit-2509/2511 | `qwen-edit` | Apache-2.0 ✅ | ~25–27 GB weights | **no** (blows 32 GB) | opt-in for >32 GB machines |
| FLUX.1 Kontext dev | `kontext` | non-commercial ✗ | 9.2 GB (mzbac quant) | fits | **rejected** — mzbac quant produces garbage with this mflux; official is HF-gated |
| Step1X-Edit v1.2 | — | Apache-2.0 ✅ | ~18 GB+ | tight | not integrated (no mflux backend) |

**Selected default: FLUX.2 Klein 4B** — the only editor that is commercial-safe (Apache-2.0) AND fits 32 GB AND downloads cleanly. mflux quantizes the official weights to 4-bit at load; peak ~5.2 GB.

## Live benchmark (M1 Pro / 32 GB, flux2-klein, via `/v1/execute` + RAM-guarded bridge)
| Fixture | Dimension | Result | Time | Min free |
|---|---|---|---|---|
| B color | change red car → blue, preserve all | ✅ excellent | 59 s | 67% |
| C background | wall → sunset sky, keep car | ✅ excellent | 58 s | 66% |
| E preserve | gold rims only, keep rest | ✅ excellent | 58 s | 67% |
| A remove | remove plant, keep mug+table | ✅ clean removal | 58 s | 66% |
| — direct diag | red → blue, 6 steps | peak **5.19 GB** | 53 s | — |

Preservation is strong across all four (subject/background/geometry retained; only the requested region changes). No fake aggregate score — each judged on adherence + preservation.

## Production gate (Phase 18) — all met
1. real local provider end-to-end ✅ (flux2-klein) · 2. image+instruction→image via `/v1/execute` ✅ · 3. Router→image.edit ✅ · 4. ambiguous→clarify ✅ · 5. typed artifacts ✅ · 6. source→result provenance ✅ (`sourceArtifactID` verified) · 7. external SSD storage ✅ · 8. Install-and-Resume wired (router returns `installRequired` when the asset is absent; asset now = FLUX.2 Klein) ✅ · 9. Model Fit ✅ · 10. real benchmark evidence ✅ · 11. cancellation (killable process group) ✅ · 12. failure recovery (typed errors: missing image/instruction/model, low-memory floor) ✅ · 13. Web before/after ✅ (existing `beforeAfterHTML`, wired on `generatedBy.capability==='image.edit'`) · 14. localized edit ✅ (E) · 15. preservation in fixtures ✅ · 16. no silent fallback to generation ✅ · 17. lifecycle/memory bounded ✅ (~5 GB peak, guarded) · 18. packaged path (mflux CLIs + SSD cache, no dev paths) ✅ · 19. no dev-machine paths ✅ · 20. full regression green ✅ (543).

## Router behavior (image attached)
`change the car color to blue` → **image.edit (ready)** · `what kind of car is this?` → image.understand · `remove the background` → image.segment · `upscale this image` → image.upscale · `make it better` → clarify. Router false-execution safety preserved.

## Memory / lifecycle
FLUX.2 Klein q4 peaks ~5.2 GB (min 66% free during edits) — the RAM-guarded bridge (`--low-ram`/VAE tiling default, memory floor, killable process group) keeps it safe; a raw diffusion run once caused a watchdog panic, so all edits go through the guarded path only.

## Known limitations
- **Qwen-Image-Edit** (higher fidelity, Apache-2.0) needs **>32 GB** — offered as an explicit opt-in backend, not the default here.
- **FLUX Kontext** stays experimental-only (non-commercial + no working local quant + gated).
- **Masked composition** (`image.segment` → mask → `image.edit`) and **reference-image edits** (flux2-edit accepts `--image-paths` plural) are supported by the runtime but not yet exposed as first-class UX — follow-ups.

## Verdict
**IMAGE EDITING & ARTIFACT TRANSFORMATION PRODUCTION-READY** on 32 GB with FLUX.2 Klein 4B. Tier C (Node) remains deferred; no release cut.
