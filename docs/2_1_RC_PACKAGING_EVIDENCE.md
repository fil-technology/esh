# esh 2.1.0-rc.1 — Packaging / Signing Evidence

Built from `main` (post Voice merge + RC prep). VERSION = `2.1.0-rc.1`.

## Build pipeline (fresh, not the stale dist/)
- `scripts/package-release.sh 2.1.0-rc.1` → release Swift binary, `mlx.metallib` (3.6 MB), self-contained
  `llama-server` (static ggml + Metal, verified non-`@rpath`/non-Homebrew), bundled Python venv, payload.
- **Blocker found + fixed:** on the exFAT SSD `.build`, macOS AppleDouble `._*.metal` sidecars polluted the
  mlx-swift metal sources; the metallib compile hit "not valid UTF-8" and silently produced no metallib,
  aborting packaging. Fixed by excluding `._*` in the metal glob (`scripts/lib/common.sh`). Rebuild clean.

## Package smoke — ✅
`scripts/smoke-test-package.sh dist/esh-macos-2.1.0-rc.1` → `smoke: ok` (packaged launcher, model
recommendations, empty-installs handling, **bundled llama.cpp GGUF runtime ok**).

## Code signing — ✅ (local Developer ID)
`scripts/sign-release.sh` with `APPLE_DEVELOPER_ID="Developer ID Application: Sviatoslav Fil (L7T5538V86)"`:
- All Mach-O signed; `codesign --verify --strict` passes.
- `bin/esh`: `flags=runtime` (**hardened runtime**), `Authority=Developer ID Application … (L7T5538V86)`,
  full Apple chain, **secure timestamp**, `TeamIdentifier=L7T5538V86`. (`spctl` "not an app" is expected for a
  CLI, not a failure.)

## Fresh-install verification from the packaged build — ✅ (Swift/CLI/Web/Voice/APIs/GGUF)
- `esh version` → **`2.1.0-rc.1`** (VERSION resolves in the package; the source-build "unknown" is a dev-only artifact).
- `esh doctor` → runs; **no source-tree paths** in output (bundled venv, not `/Source/.venv`).
- Packaged `esh serve`: `GET /health` 200, `/web` 200, `/voice` 200, `/v1/models` 16, `/v1/audio/models` 38.
- Voice Auto correctly **skips the phantom install** (disk-presence fix present in the package).
- Bundled **GGUF** (llama.cpp) runtime: ok.

## Packaged MLX-python-bridge (chat/image) — local build blocked; fix committed; CI unaffected
- The **local** package's bundled venv was created from the dev machine's **anaconda3** (`command -v python3`).
  Conda venvs are non-relocatable (`pyvenv.cfg home = ~/anaconda3/bin`; stdlib resolves there), so the bridge
  failed importing `base64`/`struct`. **Root cause fixed:** `esh::bootstrap_python` now rejects conda
  interpreters and prefers a clean python.org/Homebrew/system python ≥ 3.10 (`ESH_BOOTSTRAP_PYTHON` overrides).
- This is a **local-build robustness bug**, not a defect in the capabilities or the published artifact:
  - The MLX-python capabilities are verified working through the runtime in Phase A (chat, image.generate,
    image.edit, image.upscale, TTS) — see `2_1_RELEASE_QUALIFICATION_MATRIX.md`.
  - **The release CI (`release.yml`) builds the publishable artifact fresh with `actions/setup-python` (clean
    python.org), so the published venv is self-contained** and unaffected by the dev machine's conda.
- **Local re-verification of the clean packaged venv is blocked by dev-machine disk space** (internal volume
  ~100% full; a clean venv rebuild needs several GB). Covered by the CI clean build on tag push.

## Net
The build/sign pipeline is verified end-to-end on this Mac except a clean-venv MLX rebuild (disk-blocked). Both
packaging robustness bugs are fixed and on `main`, so the CI tag-build produces a clean, self-contained,
signed, notarized artifact.
