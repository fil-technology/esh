#!/usr/bin/env python3
"""esh audio.generate SFX worker — runs INSIDE the isolated audio runtime venv (mlx-audiocraft / AudioGen),
NOT the main esh venv, so its deps never touch the MLX LLM/VLM runtime. Reads one JSON request on stdin,
generates environmental sound with AudioGen, writes a WAV, and prints one JSON result on stdout.

Request : {"prompt","outputPath","seconds"?,"seed"?,"model"?}
Response: {"outputPath","seconds","sampleRate","channels","provider","model","license"}
"""
import os, sys, json, time
os.environ.setdefault("PYTHONUTF8", "1")


def _fail(msg: str) -> None:
    print(json.dumps({"error": msg}), flush=True)
    sys.exit(1)


def main() -> None:
    try:
        req = json.loads(sys.stdin.read() or "{}")
    except Exception as e:
        _fail(f"invalid request json: {e}")
    prompt = (req.get("prompt") or "").strip()
    out_path = req.get("outputPath")
    if not prompt or not out_path:
        _fail("audio.generate requires 'prompt' and 'outputPath'")
    seconds = max(1.0, min(30.0, float(req.get("seconds") or 8.0)))
    model_id = req.get("model") or "facebook/audiogen-medium"
    try:
        import numpy as np, soundfile as sf
        from mlx_audiocraft import AudioGen
    except Exception as e:
        _fail(f"audio runtime unavailable (mlx-audiocraft not installed in this venv): {e}")
    try:
        model = AudioGen.get_pretrained(model_id)
        model.set_generation_params(duration=seconds)
        sr = int(model.sample_rate)
        wavs = model.generate([prompt])
        arr = np.array(wavs[0])
        if arr.ndim == 3:
            arr = arr[0]
        arr = arr.T
        channels = 1 if arr.shape[1] == 1 else arr.shape[1]
        if channels == 1:
            arr = arr[:, 0]
        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
        sf.write(out_path, arr, sr)
        dur = arr.shape[0] / sr
    except Exception as e:
        _fail(f"audio generation failed: {e}")
    print(json.dumps({"outputPath": out_path, "seconds": round(dur, 3), "sampleRate": sr,
                      "channels": channels, "provider": "audiogen-mlx", "model": model_id,
                      "license": "cc-by-nc-4.0"}), flush=True)


if __name__ == "__main__":
    main()
