#!/usr/bin/env python3
"""Real-model validation of the worker-side KV-growth guard (Tools/mlx_vlm_bridge.py `_ensure_kv_headroom` and the
in-generation pressure watch), run in-process through esh's own `_generate_with_loaded_model`.

  1. bytes/token derived from the loaded model match its config
  2. an unsatisfiable context (huge max_tokens) is REFUSED before prefill with an actionable message (no mocks)
  3. when memory is short, the worker drops its own idle session caches first and then proceeds
  4. critical pressure during generation stops cleanly with finishReason=memory_pressure and partial output

  python benchmarks/validate_kv_guard.py --model <mlx dir>
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "Tools"))
spec = importlib.util.spec_from_file_location("bridge", REPO / "Tools" / "mlx_vlm_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    a = p.parse_args()
    mx, _gs, stream_generate, KVCache, make_prompt_cache, load = bridge._import_mlx_lm()
    model, tok = bridge._load_mlx_model(load, a.model)
    cfg = json.loads((Path(a.model) / "config.json").read_text())
    results = {}

    def gen(max_tokens, text="Write a numbered list of twenty fruits.", mode="tokens", state=None):
        os.environ["ESH_MLX_PREFIX_CACHE"] = mode
        req = {"modelID": "kv-guard", "kvMode": "raw", "session": {"messages": [{"role": "user", "text": text}]},
               "stateFilePath": state or os.path.join(tempfile.mkdtemp(), "s.json"),
               "config": {"maxTokens": max_tokens, "temperature": 0.0, "enableThinking": False}}
        return bridge._generate_with_loaded_model(mx, stream_generate, KVCache, make_prompt_cache, model, tok, req,
                                                  on_token=lambda _t: None)

    # 1
    expected = cfg["num_hidden_layers"] * cfg.get("num_key_value_heads", cfg["num_attention_heads"]) * \
        (cfg.get("head_dim") or cfg["hidden_size"] // cfg["num_attention_heads"]) * 4
    results["bytesPerToken"] = {"bridge": bridge._kv_bytes_per_token(model), "config": expected,
                                "ok": bridge._kv_bytes_per_token(model) == expected}
    # 2 (real host numbers, no mocks): 10M new tokens cannot fit anywhere
    try:
        gen(10_000_000)
        results["refusal"] = {"ok": False, "detail": "was not refused"}
    except RuntimeError as exc:
        msg = str(exc)
        results["refusal"] = {"ok": "Shorten the conversation" in msg and "KV cache" in msg, "message": msg[:240]}
    # 3 drop-before-refuse: hold a live cache, make the first check fail and the re-check pass
    gen(8, mode="live")
    held = bridge._live_cache_resident_bytes()
    calls = {"n": 0}

    def flaky(_bytes):
        calls["n"] += 1
        return "simulated: not enough memory" if calls["n"] == 1 else None
    with mock.patch.object(bridge, "_kv_growth_refusal", side_effect=flaky):
        # a DIFFERENT conversation, so the held cache is idle (not popped as this request's own prefix)
        r = gen(8, text="Name the planets of the solar system.", mode="live")
    results["dropBeforeRefuse"] = {"ok": held > 0 and r["metrics"].get("kvGuardFreedBytes") == held,
                                   "heldBytes": held, "freedBytes": r["metrics"].get("kvGuardFreedBytes")}
    # 4 pressure during generation
    with mock.patch.object(bridge, "_mem_pressure_critical", return_value=True), \
            mock.patch.object(bridge, "_KV_GUARD_CHECK_EVERY", 16):
        r = gen(200)
    results["pressureStop"] = {"ok": r["metrics"].get("finishReason") == "memory_pressure" and 0 < len(r["text"]),
                               "finishReason": r["metrics"].get("finishReason"),
                               "generationTokens": r["metrics"].get("generationTokens"), "textChars": len(r["text"])}
    # metrics carry the guard's numbers on a normal request
    r = gen(16)
    results["metrics"] = {k: r["metrics"].get(k) for k in ("kvGrowthBytes", "kvBytesPerToken", "kvGuardFreedBytes",
                                                           "finishReason")}
    results["allOk"] = all(v.get("ok", True) for v in results.values() if isinstance(v, dict))
    print(json.dumps(results, indent=1))


if __name__ == "__main__":
    main()
