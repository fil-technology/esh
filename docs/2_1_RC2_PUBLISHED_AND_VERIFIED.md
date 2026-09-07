# ESH 2.1 RC PUBLISHED AND VERIFIED — READY FOR SOAK

**Published RC: `v2.1.0-rc.2`** (rc.1 was withdrawn — see below). Validated against the **actual CI-built,
signed, notarized artifact**, not a source build.

## Why rc.2, not rc.1
Validating the real distributed artifact caught a genuine release blocker in rc.1: `package-release.sh` omitted
`Tools/esh_audiogen.py`, so **`audio.generate` (neural SFX — a Production capability) crashed** in the shipped
package (`can't open esh_audiogen.py`). Fixed the packaging, bumped to **rc.2** (repo policy increments RC, as
2.0.0 did rc.1→rc.7), deleted the defective rc.1 prerelease+tag, and re-validated. audio.generate now works in
the distributed artifact.

## Distribution verification (CI-built zip, checksum-matched)
- SHA-256 **MATCH**; **Developer ID** (L7T5538V86) + **hardened runtime** + secure timestamp; `spctl` →
  **accepted / Notarized Developer ID**.
- Bundled venv references **python.org 3.10**, not anaconda (conda fix proven in the real build); **no
  `/Users/...` dev-path leaks**; `esh version` → **2.1.0-rc.2**; `esh_audiogen.py` present (all 4 `Tools/` files).
- `bin/esh` deps: only OS Swift runtime; bundled `llama-server` fully self-contained.

## Distributed-runtime smoke (all against the notarized artifact)
doctor `status: ok` (`mlx: ready`, `llama.cpp: ready`) · **MLX chat**, **GGUF chat**, **Apple Foundation Models
available**, warm reuse · `/health` `/web` `/voice` `/v1/models` `/v1/tools` all 200 · **TTS→STT round-trip** ·
`vector.generate` · **`audio.generate` (the fix)**. Voice WS: `/voice` 200 + **`101 Switching Protocols`** on
ws://…:11436. Offline (HF forced offline): chat/TTS/STT/vector all OK, **no internal-disk cache growth**.
Upgrade path: `brew outdated --cask esh` empty (stable stays **2.0.0**); RC opt-in installs 2.1.0-rc.2; stable
binary untouched for rollback.

---

## Handover

1. **GitHub prerelease:** https://github.com/fil-technology/esh/releases/tag/v2.1.0-rc.2 — **prerelease, published, not draft**. Stable `latest` = `v2.0.0`; Homebrew cask = `2.0.0` (untouched).

2. **Exact RC install (opt-in; does not touch stable):**
   ```bash
   cd ~/Downloads
   gh release download v2.1.0-rc.2 --repo fil-technology/esh --pattern 'esh-macos-2.1.0-rc.2.zip'
   ditto -x -k esh-macos-2.1.0-rc.2.zip .
   "$PWD/esh-macos-2.1.0-rc.2/bin/esh" serve
   ```
   (Run by full path so it never shadows the brew-managed stable `esh`. First run provisions `~/.esh/runtime`; a host `python` is required — the cask normally provides it via `depends_on formula: "python"`.)

3. **Expected version:** `esh version` → **`2.1.0-rc.2`**

4. **Web URL:** http://127.0.0.1:11435/web  (default serve port 11435)

5. **Voice URL:** page http://127.0.0.1:11435/voice · realtime WS ws://127.0.0.1:11436/v1/voice/stream

6. **Known Experimental (labeled):** `music.generate` (MusicGen, CC-BY-NC), `image.edit` `kontext` backend (FLUX.1 Kontext, non-commercial), `image.segment` (rembg), `audio.diarize` (sherpa-onnx). *(`audio.generate` is Production; its AudioGen model is CC-BY-NC — disclosed.)*

7. **Known non-blocking limitations:**
   - **image.generate / image.edit / image.upscale** need the **optional `mflux`** dep, installed **on-demand** via the web/router install-and-resume flow (not bundled) — raw `/v1/execute` before install returns "mflux is not available".
   - **Notarization ticket is not stapled** to the inner binary (notarized + `spctl`-accepted online; a fully-offline *first* launch on a machine that has never seen it would need one online check). Candidate for a `stapler staple` step post-rc.
   - `doctor`'s "voice auto llm" line can name an incomplete/phantom model; the serve path selects correctly (disk-presence filter). Cosmetic — flagged for rc.3.

8. **Rollback:** stable was never replaced — `/opt/homebrew/bin/esh` is still `2.0.0`. To drop the RC: `rm -rf ~/Downloads/esh-macos-2.1.0-rc.2*` (and `rm -rf ~/.esh/runtime` to discard the provisioned RC runtime). To reassert stable: `brew reinstall --cask esh`.

## 1–2 day soak checklist (normal use)
- [ ] **chat** — a few multi-turn conversations, tool-calling model
- [ ] **images** — image.generate (triggers mflux install on first use), an edit, an upscale
- [ ] **projects** — project.generate + a **Three.js** project; open in Web
- [ ] **STT/TTS** — dictate + speak back
- [ ] **SFX/music** — audio.generate (SFX), music.generate (experimental)
- [ ] **video understanding** — a short clip
- [ ] **Voice** — a live /voice session: VAD, barge-in, latency feel
- [ ] **Auto routing** — natural-language requests routed to the right capability
- [ ] **model install/remove** — install one, remove one; doctor reflects it
- [ ] **external SSD reconnect** — unplug/replug the model SSD; verify graceful recovery
- [ ] **offline use** — pull network; chat/STT/TTS/Voice from local assets
- [ ] **Web UI** — /web across the above
- [ ] **API clients** — point an OpenAI-compatible client at :11435

_No further development. No stable `v2.1.0` until soak passes._
