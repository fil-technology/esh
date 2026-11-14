#!/usr/bin/env python3
"""Final validation of the persistent-MLX prefix-cache modes through the real `esh serve` (OpenAI API), with an
Ashex-shaped workload, before proposing `live` as the default for persistent MLX workers.

Scenarios per mode (legacy = pre-2026-11 baseline, tokens = current default, live = candidate):
  long        one agent conversation of 10 turns over a growing ~1.6K+ token context
  concurrent  3 different conversations at once (4 turns each); each must equal its own serial run
  switching   alternate requests between an MLX model and a GGUF model in the same server
  budget      (live only) ESH_MLX_LIVE_PREFIX_MAX_BYTES tiny -> caches not retained, outputs still correct
  growth      impossible context (huge max_tokens) -> actionable error, pool stays consistent, next request fine
  restart     SIGTERM mid-conversation, restart, continue: correct, no orphan processes, no leftover state

  python benchmarks/serve_live_validation.py --mlx-model <id> --gguf-model <id> [--esh-home <dir>]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import esh_infer_bench as bench  # noqa: E402
from serve_integration import AGENT, CONVO_B, Server, tree_rss_gb  # noqa: E402

FOLLOWUPS = [
    "Which method would you change to fix the failing test? Method name only.",
    "Write the one-line fix for that method's guard.",
    "Does `append(_:to:)` enforce the quota before or after writing? One sentence.",
    "What happens in `compact(to:)` when every session is newer than the cutoff? One sentence.",
    "Name one race condition the actor prevents. One sentence.",
    "Suggest a better name for `totalBytes()`. Name only.",
    "Which error does `load(_:)` throw for a missing file? Name only.",
    "Give a one-line doc comment for `remove(_:)`.",
    "Summarize the type in one sentence.",
]
CONVO_C = [
    "Explain in two sentences what a KV cache is in a transformer.",
    "Why does it grow linearly with context? One sentence.",
    "How does quantizing it help? One sentence.",
    "Give one downside of 4-bit KV caches. One sentence.",
]


def converse(server, model, turns, max_tokens=96):
    msgs, out = [], []
    for t in turns:
        msgs.append({"role": "user", "content": t})
        r = server.chat(model, msgs, max_tokens=max_tokens)
        msgs.append({"role": "assistant", "content": r["text"]})
        out.append(r)
    return out


def orphans():
    out = subprocess.run(["pgrep", "-fl", "mlx_vlm_bridge.py mlx-serve|llama-server -m"], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if l.strip()]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--esh", default=str(bench.REPO / "macos" / ".build" / "debug" / "esh"))
    p.add_argument("--mlx-model", required=True)
    p.add_argument("--gguf-model", required=True)
    p.add_argument("--esh-home", default=None)
    p.add_argument("--port", type=int, default=18300)
    p.add_argument("--out", default=str(bench.REPO / "benchmarks" / "results" / "serve-live-validation.jsonl"))
    a = p.parse_args()
    base_env = {"ESH_MLX_PERSISTENT": "1"}
    if a.esh_home:
        base_env["ESH_HOME"] = a.esh_home
    long_turns = [AGENT[0]] + FOLLOWUPS
    results, reference = [], {}
    port = a.port
    for mode in ("legacy", "tokens", "live"):
        rec = {"mode": mode}
        env = {**base_env, "ESH_MLX_PREFIX_CACHE": mode}
        port += 1
        server = Server(a.esh, port, env)
        try:
            t0 = time.perf_counter()
            long = converse(server, a.mlx_model, long_turns)
            rec["long"] = {"ttft": [round(r["ttft"] or 0, 2) for r in long], "e2e": [round(r["e2e"], 2) for r in long],
                           "sessionSeconds": round(time.perf_counter() - t0, 2)}
            serial_b = converse(server, a.mlx_model, CONVO_B)
            serial_c = converse(server, a.mlx_model, CONVO_C)
            box = {}
            threads = [threading.Thread(target=lambda k=k, t=t: box.__setitem__(k, converse(server, a.mlx_model, t)))
                       for k, t in (("a", AGENT), ("b", CONVO_B), ("c", CONVO_C))]
            t0 = time.perf_counter(); [t.start() for t in threads]; [t.join() for t in threads]
            rec["concurrent"] = {"wallSeconds": round(time.perf_counter() - t0, 2),
                                 "equalsSerial": {"b": [x["text"] for x in box["b"]] == [x["text"] for x in serial_b],
                                                  "c": [x["text"] for x in box["c"]] == [x["text"] for x in serial_c],
                                                  # same first prompt as the long conversation's first turn
                                                  "aFirstTurn": box["a"][0]["text"] == long[0]["text"]}}
            # model switching: MLX turn, GGUF turn, MLX continuation
            sw_msgs = [{"role": "user", "content": CONVO_C[0]}]
            m1 = server.chat(a.mlx_model, sw_msgs)
            g1 = server.chat(a.gguf_model, [{"role": "user", "content": "Say hello in five words."}])
            sw_msgs += [{"role": "assistant", "content": m1["text"]}, {"role": "user", "content": CONVO_C[1]}]
            m2 = server.chat(a.mlx_model, sw_msgs)
            rt = server.runtime()
            rec["switching"] = {"mlxSecondTurnEqualsSerial": m2["text"] == serial_c[1]["text"],
                                "mlxSecondTurnTTFT": round(m2["ttft"] or 0, 2), "ggufOk": bool(g1["text"]),
                                "residents": [(r["modelID"], r["state"]) for r in rt["residents"]],
                                "residentCacheGB": rt.get("residentCacheGB")}
            # growth guard
            try:
                server.chat(a.mlx_model, [{"role": "user", "content": "hi"}], max_tokens=10_000_000)
                rec["growth"] = {"refused": False}
            except Exception as exc:  # noqa: BLE001
                ok_after = server.chat(a.mlx_model, [{"role": "user", "content": CONVO_C[0]}])
                rt2 = server.runtime()
                rec["growth"] = {"refused": "Not enough memory" in str(exc) or "context" in str(exc).lower(),
                                 "message": str(exc)[:200], "nextRequestOk": bool(ok_after["text"]),
                                 "activeAfter": rt2.get("activeRequests")}
            rec["serverPeakRssGB"] = round(server.peak_rss, 2)
            rec["texts"] = {"long": [r["text"] for r in long], "b": [r["text"] for r in serial_b],
                            "c": [r["text"] for r in serial_c]}
            if mode == "legacy":
                reference = rec["texts"]
            rec["identicalToLegacy"] = {k: [x == y for x, y in zip(reference[k], v)] for k, v in rec["texts"].items()}
        except Exception as exc:  # noqa: BLE001
            rec["aborted"] = str(getattr(server, "tripped", None) or exc)[:300]
        finally:
            server.stop()
            time.sleep(3)
        rec["orphansAfterStop"] = orphans()
        print(json.dumps({k: v for k, v in rec.items() if k != "texts"})[:1500], flush=True)
        results.append(rec)

    # live-only: tiny budget + restart mid-conversation
    extra = {"mode": "live-extra"}
    port += 1
    server = Server(a.esh, port, {**base_env, "ESH_MLX_PREFIX_CACHE": "live", "ESH_MLX_LIVE_PREFIX_MAX_BYTES": "1000000"})
    try:
        tiny = converse(server, a.mlx_model, CONVO_C)
        extra["tinyBudget"] = {"equalsLegacy": [r["text"] for r in tiny] == reference.get("c"),
                               "residentCacheGB": server.runtime().get("residentCacheGB")}
    finally:
        server.stop(); time.sleep(3)
    port += 1
    server = Server(a.esh, port, {**base_env, "ESH_MLX_PREFIX_CACHE": "live"})
    msgs = [{"role": "user", "content": CONVO_C[0]}]
    r1 = server.chat(a.mlx_model, msgs)
    server.stop(); time.sleep(3)
    extra["orphansAfterKill"] = orphans()
    state_dir = Path(os.environ.get("TMPDIR", "/tmp")) / "esh-mlx-state"
    port += 1
    server = Server(a.esh, port, {**base_env, "ESH_MLX_PREFIX_CACHE": "live"})
    try:
        msgs += [{"role": "assistant", "content": r1["text"]}, {"role": "user", "content": CONVO_C[1]}]
        r2 = server.chat(a.mlx_model, msgs)
        extra["restart"] = {"firstTurnEqualsLegacy": r1["text"] == reference.get("c", [None])[0],
                            "continuedTurnEqualsLegacy": r2["text"] == reference.get("c", [None, None])[1],
                            "staleStateFiles": sorted(x.name for x in state_dir.glob("*") if x.is_file())}
    finally:
        server.stop(); time.sleep(3)
    extra["orphansAtEnd"] = orphans()
    print(json.dumps(extra)[:1200], flush=True)
    results.append(extra)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    with Path(a.out).open("a") as f:
        for r in results:
            f.write(json.dumps({**r, "date": time.strftime("%Y-%m-%dT%H:%M:%S")}) + "\n")


if __name__ == "__main__":
    main()
