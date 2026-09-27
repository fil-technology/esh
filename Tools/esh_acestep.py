#!/usr/bin/env python3
"""esh music.generate worker for ACE-Step 1.5 — runs INSIDE the ACE-Step uv-managed venv (torch/torchcodec/
torchao/MLX), NOT the main esh venv. ACE-Step ships as a git project (no pip package), so esh discovers its
checkout + venv via env and re-execs this worker there. Reads one JSON request on stdin, generates a full song
(48 kHz stereo) with the DiT (MPS) + native MLX VAE decode + the 5 Hz MLX LM, writes a WAV, prints one JSON.

Request : {"caption","outputPath","lyrics"?("[Instrumental]"),"seconds"?(30),"steps"?(8),"seed"?,"checkpointDir"?,
           "config"?("acestep-v15-turbo"),"lmModel"?("acestep-5Hz-lm-0.6B")}
Response: {"outputPath","seconds","sampleRate","channels","provider","license"}
License  : MIT (ACE-Step 1.5) — commercial-safe.
"""
import os, sys, json, glob, shutil, tempfile
os.environ.setdefault("PYTHONUTF8", "1")


def _fail(msg: str) -> None:
    print(json.dumps({"error": msg}), flush=True)
    sys.exit(1)


def main() -> None:
    try:
        req = json.loads(sys.stdin.read() or "{}")
    except Exception as e:  # noqa: BLE001
        _fail(f"invalid request json: {e}")
    caption = (req.get("caption") or req.get("prompt") or "").strip()
    out_path = req.get("outputPath")
    if not caption or not out_path:
        _fail("ACE-Step requires 'caption' and 'outputPath'")
    lyrics = req.get("lyrics") or "[Instrumental]"
    seconds = float(req.get("seconds") or 30.0)
    steps = int(req.get("steps") or 8)
    seed = int(req.get("seed") if req.get("seed") is not None else 42)
    config_name = req.get("config") or "acestep-v15-turbo"
    lm_model = req.get("lmModel") or "acestep-5Hz-lm-0.6B"

    ace_home = os.environ.get("ESH_ACESTEP_HOME")
    if not ace_home or not os.path.isdir(ace_home):
        _fail("ACE-Step checkout not found (set ESH_ACESTEP_HOME to the ace-step-1.5 repo)")
    sys.path.insert(0, ace_home)
    ckpt = req.get("checkpointDir") or os.environ.get("ACESTEP_CHECKPOINTS_DIR") or os.path.join(ace_home, "checkpoints")
    os.environ["ACESTEP_CHECKPOINTS_DIR"] = ckpt

    try:
        from acestep.handler import AceStepHandler
        from acestep.llm_inference import LLMHandler
        from acestep.inference import GenerationParams, GenerationConfig, generate_music
    except Exception as e:  # noqa: BLE001
        _fail(f"ACE-Step runtime unavailable (checkout/venv not set up): {type(e).__name__}: {e}")

    try:
        dit = AceStepHandler()
        msg, ok = dit.initialize_service(project_root=ace_home, config_path=config_name, device="auto", offload_to_cpu=False)
        if not ok:
            _fail(f"ACE-Step DiT init failed: {msg}")
        llm = LLMHandler()
        msg, ok = llm.initialize(checkpoint_dir=ckpt, lm_model_path=lm_model, backend="mlx", device="auto", offload_to_cpu=False, dtype=None)
        if not ok:
            _fail(f"ACE-Step 5Hz LM init failed: {msg}")
        with tempfile.TemporaryDirectory(dir=os.path.dirname(out_path) or None) as td:
            params = GenerationParams(task_type="text2music", thinking=True, caption=caption, lyrics=lyrics,
                                      vocal_language=req.get("language", "en"), duration=seconds,
                                      inference_steps=steps, guidance_scale=float(req.get("guidance") or 1.0), seed=seed)
            config = GenerationConfig(batch_size=1, audio_format="wav")
            res = generate_music(dit, llm, params=params, config=config, save_dir=td)
            if not res.success:
                _fail(f"ACE-Step generation failed: {res.status_message}")
            wavs = [a.get("path") for a in res.audios if a.get("path")] or glob.glob(os.path.join(td, "*.wav"))
            if not wavs:
                _fail("ACE-Step produced no audio")
            os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
            shutil.copyfile(wavs[0], out_path)
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001
        _fail(f"ACE-Step generation failed: {type(e).__name__}: {e}")

    try:
        import soundfile as sf
        info = sf.info(out_path)
        dur, srate, ch = round(info.frames / info.samplerate, 3), info.samplerate, info.channels
    except Exception:  # noqa: BLE001
        dur, srate, ch = seconds, 48000, 2
    print(json.dumps({"outputPath": out_path, "seconds": dur, "sampleRate": srate, "channels": ch,
                      "provider": "ace-step-1.5", "license": "mit"}), flush=True)


if __name__ == "__main__":
    main()
