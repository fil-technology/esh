#!/usr/bin/env python3
"""esh audio.cloneVoice worker — runs INSIDE the isolated voice-clone venv (coqui-tts / XTTS-v2), NOT the main
esh venv, so its torch<2.9 / transformers<5 pins never touch the MLX LLM/VLM runtime. Reads one JSON request on
stdin, synthesizes `text` in the reference speaker's voice, writes a WAV, and prints one JSON result on stdout.

Request : {"text","referencePath","outputPath","language"?,"hfCache"?}
Response: {"outputPath","provider","license","language","sampleRate"?}
License  : Coqui Public Model License (CPML) — NON-COMMERCIAL (dogfood-only).
"""
import os, sys, json
os.environ.setdefault("PYTHONUTF8", "1")
# XTTS asks to accept its non-commercial license interactively; accept it non-interactively (dogfood).
os.environ.setdefault("COQUI_TOS_AGREED", "1")


def _fail(msg: str) -> None:
    print(json.dumps({"error": msg}), flush=True)
    sys.exit(1)


def main() -> None:
    try:
        req = json.loads(sys.stdin.read() or "{}")
    except Exception as e:  # noqa: BLE001
        _fail(f"invalid request json: {e}")
    text = (req.get("text") or "").strip()
    reference = req.get("referencePath")
    out_path = req.get("outputPath")
    language = (req.get("language") or "en").strip() or "en"
    if not text or not out_path:
        _fail("voice cloning requires 'text' and 'outputPath'")
    if not reference or not os.path.exists(reference):
        _fail("voice cloning requires an existing reference audio sample")

    # Keep the coqui model store on the configured assets volume (external SSD), not the internal user dir.
    hf_cache = req.get("hfCache")
    if hf_cache:
        os.environ.setdefault("TTS_HOME", os.path.join(hf_cache, "coqui"))
        try:
            os.makedirs(os.environ["TTS_HOME"], exist_ok=True)
        except Exception:  # noqa: BLE001
            pass

    try:
        import torch  # noqa: F401
        from TTS.api import TTS
    except Exception as e:  # noqa: BLE001
        _fail(f"voice-clone runtime unavailable (coqui-tts not installed in this venv): {type(e).__name__}: {e}")

    # Apple Silicon: XTTS runs on CPU reliably; MPS support in coqui-tts is uneven, so pin CPU for determinism.
    try:
        tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2")
        try:
            tts.to("cpu")
        except Exception:  # noqa: BLE001
            pass
        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
        tts.tts_to_file(text=text, speaker_wav=reference, language=language, file_path=out_path)
    except Exception as e:  # noqa: BLE001
        _fail(f"voice cloning failed: {type(e).__name__}: {e}")

    if not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
        _fail("voice cloning produced no audio")
    print(json.dumps({"outputPath": out_path, "provider": "xtts-v2",
                      "license": "cpml-noncommercial", "language": language}), flush=True)


if __name__ == "__main__":
    main()
