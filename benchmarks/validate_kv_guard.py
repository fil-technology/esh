#!/usr/bin/env python3
"""Real-model validation of the worker-side KV-growth guard (Tools/mlx_vlm_bridge.py `_ensure_kv_headroom` and the
in-generation pressure watch), run in-process through esh's own `_generate_with_loaded_model`.

  1. bytes/token derived from the loaded model match its config
  2. an unsatisfiable context (huge max_tokens) is REFUSED before prefill with an actionable message (no mocks)
  3. after a refusal the worker stays usable: the next valid request succeeds with the same greedy text as before it
  4. when memory is short, the persistent worker drops its own idle session caches first and then proceeds
  5. when memory is short and there is nothing idle to drop, the request is refused cleanly and the next one works
  6. critical pressure during generation stops cleanly with finishReason=memory_pressure and partial output

Every check is recorded even when an earlier one fails, so the report is always complete; the exit code is 1 unless
all checks pass.

Live session caches only exist in the managed persistent worker (`mlx-serve` sets `_IN_PERSISTENT_WORKER`; elsewhere a
`live` request runs as `tokens`). Checks 4-5 therefore run with that flag set, exactly as the worker sets it.

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

PROMPT = "Write a numbered list of twenty fruits."


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    a = p.parse_args()
    mx, _gs, stream_generate, KVCache, make_prompt_cache, load = bridge._import_mlx_lm()
    model, tok = bridge._load_mlx_model(load, a.model)
    cfg = json.loads((Path(a.model) / "config.json").read_text())
    results: dict = {"model": a.model}
    # Default state files (and KV sidecars) live here; TemporaryDirectory removes it when main() ends or on exit.
    scratch = tempfile.TemporaryDirectory(prefix="esh-kvguard-")
    fresh = iter(range(1_000_000))

    def gen(max_tokens, text=PROMPT, mode="tokens", state=None):
        os.environ["ESH_MLX_PREFIX_CACHE"] = mode
        req = {"modelID": "kv-guard", "kvMode": "raw", "session": {"messages": [{"role": "user", "text": text}]},
               "stateFilePath": state or os.path.join(scratch.name, f"s{next(fresh)}.json"),
               "config": {"maxTokens": max_tokens, "temperature": 0.0, "enableThinking": False}}
        return bridge._generate_with_loaded_model(mx, stream_generate, KVCache, make_prompt_cache, model, tok, req,
                                                  on_token=lambda _t: None)

    def check(name, fn):
        """Run one check; an unexpected exception becomes a failed entry instead of aborting the report."""
        try:
            results[name] = fn()
        except Exception as exc:  # noqa: BLE001
            results[name] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"[:400]}

    def refusal_message(fn):
        try:
            fn()
        except RuntimeError as exc:
            return str(exc)
        return None

    def actionable(msg):
        return msg is not None and "Not enough memory" in msg and "Shorten the conversation" in msg

    def bytes_per_token():
        expected = cfg["num_hidden_layers"] * cfg.get("num_key_value_heads", cfg["num_attention_heads"]) * \
            (cfg.get("head_dim") or cfg["hidden_size"] // cfg["num_attention_heads"]) * 4
        got = bridge._kv_bytes_per_token(model)
        return {"ok": got == expected, "bridge": got, "config": expected}

    baseline = {}

    def refusal():
        # Real host numbers, no mocks: 10M new tokens cannot fit anywhere.
        baseline["text"] = gen(16)["text"]
        msg = refusal_message(lambda: gen(10_000_000))
        return {"ok": actionable(msg) and "KV cache" in msg, "message": (msg or "was not refused")[:240]}

    def recovery_after_refusal():
        r = gen(16)
        return {"ok": bool(r["text"]) and r["text"] == baseline.get("text"),
                "sameGreedyTextAsBeforeRefusal": r["text"] == baseline.get("text"), "textChars": len(r["text"])}

    def drop_before_refuse():
        with mock.patch.object(bridge, "_IN_PERSISTENT_WORKER", True):
            bridge._drop_live_caches()
            gen(8, mode="live")                                   # leaves one idle session cache resident
            held = bridge._live_cache_resident_bytes()
            calls = {"n": 0}

            def first_check_fails(_bytes):
                calls["n"] += 1
                return "simulated: not enough memory" if calls["n"] == 1 else None
            with mock.patch.object(bridge, "_kv_growth_refusal", side_effect=first_check_fails):
                # a DIFFERENT conversation, so the held cache is idle (not popped as this request's own prefix)
                r = gen(8, text="Name the planets of the solar system.", mode="live")
            freed = r["metrics"].get("kvGuardFreedBytes")
            bridge._drop_live_caches()
        return {"ok": held > 0 and freed == held and calls["n"] == 2 and bool(r["text"]),
                "heldBytes": held, "freedBytes": freed, "guardChecks": calls["n"]}

    def refuse_without_idle_caches():
        with mock.patch.object(bridge, "_IN_PERSISTENT_WORKER", True):
            bridge._drop_live_caches()
            with mock.patch.object(bridge, "_kv_growth_refusal", return_value="simulated: not enough memory"):
                msg = refusal_message(lambda: gen(8, mode="live"))
            after = gen(16)
        return {"ok": actionable(msg) and after["text"] == baseline.get("text"),
                "message": (msg or "was not refused")[:240], "nextRequestOk": after["text"] == baseline.get("text")}

    def pressure_stop():
        with mock.patch.object(bridge, "_mem_pressure_critical", return_value=True), \
                mock.patch.object(bridge, "_KV_GUARD_CHECK_EVERY", 16):
            r = gen(200)
        return {"ok": r["metrics"].get("finishReason") == "memory_pressure" and 0 < len(r["text"]),
                "finishReason": r["metrics"].get("finishReason"),
                "generationTokens": r["metrics"].get("generationTokens"), "textChars": len(r["text"])}

    def normal_metrics():
        r = gen(16)
        m = {k: r["metrics"].get(k) for k in ("kvGrowthBytes", "kvBytesPerToken", "kvGuardFreedBytes", "finishReason")}
        return {"ok": bool(m["kvGrowthBytes"]) and m["kvGuardFreedBytes"] == 0, **m}

    check("bytesPerToken", bytes_per_token)
    check("refusal", refusal)
    check("recoveryAfterRefusal", recovery_after_refusal)
    check("dropBeforeRefuse", drop_before_refuse)
    check("refusalWithoutIdleCaches", refuse_without_idle_caches)
    check("pressureStop", pressure_stop)
    check("metrics", normal_metrics)
    results["allOk"] = all(v.get("ok", True) for v in results.values() if isinstance(v, dict))
    print(json.dumps(results, indent=1))
    return 0 if results["allOk"] else 1


if __name__ == "__main__":
    sys.exit(main())
