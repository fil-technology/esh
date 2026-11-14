#!/usr/bin/env python3
"""SDK vs `esh serve` with equivalent configurations (Phase 5 of the managed-SDK work).

The same workload runs through
  * the public Swift SDK (`EshRuntime`), one-shot and managed — via the env-gated `SDKRuntimeBenchmark` test, and
  * `esh serve` (OpenAI API) — via the serve harness used for the earlier validation,
for one MLX model and one GGUF model. Equivalent configuration:
  * MLX: managed SDK = `MLXBackend(persistent: true)` in the SDK's pool; serve = `ESH_MLX_PERSISTENT=1`. Both use the
    default prefix-cache rule (`live` in a persistent worker, `tokens` otherwise).
  * GGUF: the SDK runs llama.cpp in-process (`LlamaCppEmbeddedBackend`, n_ctx 8192); serve spawns llama-server with
    `-c 8192`. Same weights, same context size, greedy decoding.
  * Workload: a 10-turn agent conversation over a ~1.6K-token code context (max_tokens 96, temperature 0), then 3
    conversations at once, each compared to its serial run.

Metrics per side: TTFT per turn, end-to-end per turn, session seconds, decode/prefill tok/s (when reported), cache hit
+ cached tokens, model load count, peak RSS (process + children), RSS after shutdown, leftover processes.

  python benchmarks/sdk_vs_serve.py --esh-home <store> --mlx-model <id> --gguf-model <id>
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import esh_infer_bench as bench  # noqa: E402
from serve_integration import AGENT, CONVO_B, Server  # noqa: E402
from serve_live_validation import CONVO_C, FOLLOWUPS, converse, orphans  # noqa: E402

REPO = bench.REPO
SKIP_ONESHOT_CONCURRENT: dict = {}


def script(max_tokens: int, ctx: int) -> dict:
    return {"long": [AGENT[0]] + FOLLOWUPS, "concurrent": [AGENT, CONVO_B, CONVO_C], "maxTokens": max_tokens,
            "contextTokens": ctx}


def run_sdk(model: str, lifecycle: str, home: str, script_path: str, out: str) -> dict | None:
    env = dict(os.environ)
    reuse = lifecycle.endswith("+reuse")          # e.g. sdk-managed+reuse: embedded GGUF prefix reuse on
    lifecycle = lifecycle.replace("+reuse", "")
    env.update({"ESH_SDK_BENCH_GGUF_REUSE": "1" if reuse else "0",
                # one-shot loads a model copy per concurrent request: skip that part for big models (memory safety)
                "ESH_SDK_BENCH_SKIP_CONCURRENT": "1" if (lifecycle == "oneShot" and SKIP_ONESHOT_CONCURRENT.get(model)) else "0"})
    env.update({"ESH_SDK_BENCH_MODEL": model, "ESH_SDK_BENCH_LIFECYCLE": lifecycle, "ESH_SDK_BENCH_HOME": home,
                "ESH_SDK_BENCH_SCRIPT": script_path, "ESH_SDK_BENCH_OUT": out,
                "ESH_MLX_VLM_BRIDGE": str(bench.BRIDGE), "ESH_PYTHON": sys.executable})
    before = Path(out).read_text().count("\n") if Path(out).exists() else 0
    proc = subprocess.run(["swift", "test", "--skip-build", "--filter", "SDKRuntimeBenchmark/sdkSession"],
                          cwd=REPO, env=env, capture_output=True, text=True)
    lines = Path(out).read_text().splitlines() if Path(out).exists() else []
    if len(lines) <= before:
        print(proc.stdout[-3000:], proc.stderr[-3000:], file=sys.stderr)
        return None
    rec = json.loads(lines[-1])
    rec["testPassed"] = proc.returncode == 0
    return rec


def run_serve(esh: str, model: str, home: str, port: int, sc: dict) -> dict:
    env = {"ESH_MLX_PERSISTENT": "1", "ESH_HOME": home}
    server = Server(esh, port, env)
    rec = {"side": "serve", "lifecycle": "managed", "model": model}
    try:
        t0 = time.perf_counter()
        long = converse(server, model, sc["long"], max_tokens=sc["maxTokens"])
        rec["long"] = {"ttft": [round(r["ttft"] or 0, 2) for r in long], "e2e": [round(r["e2e"], 2) for r in long],
                       "sessionSeconds": round(time.perf_counter() - t0, 2)}
        serial = [[r["text"] for r in converse(server, model, c, max_tokens=sc["maxTokens"])] for c in sc["concurrent"]]
        import threading
        box: dict = {}
        threads = [threading.Thread(target=lambda i=i, c=c: box.__setitem__(i, [r["text"] for r in converse(server, model, c, max_tokens=sc["maxTokens"])]))
                   for i, c in enumerate(sc["concurrent"])]
        t0 = time.perf_counter(); [t.start() for t in threads]; [t.join() for t in threads]
        rec["concurrent"] = {"wallSeconds": round(time.perf_counter() - t0, 2),
                             "equalsSerial": [box.get(i) == s for i, s in enumerate(serial)]}
        rt = server.runtime()
        rec["pool"] = {"residents": [{k: r.get(k) for k in ("modelID", "state", "residency", "loadCount", "measuredMemoryBytes",
                                                             "residentCacheBytes", "prefixCacheMode")} for r in rt["residents"]],
                       "residentCacheGB": rt.get("residentCacheGB")}
        rec["peakRssGB"] = round(server.peak_rss, 2)
        rec["texts"] = [r["text"] for r in long]
    finally:
        server.stop()
        time.sleep(3)
    rec["orphansAfterStop"] = orphans()
    return rec


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--esh", default=str(REPO / "macos" / ".build" / "debug" / "esh"))
    p.add_argument("--esh-home", required=True)
    p.add_argument("--mlx-model")
    p.add_argument("--gguf-model")
    p.add_argument("--max-tokens", type=int, default=96)
    p.add_argument("--context", type=int, default=8192)
    p.add_argument("--port", type=int, default=18400)
    p.add_argument("--sides", default="sdk-oneShot,sdk-managed,serve")
    p.add_argument("--gguf-extra-sides", default="sdk-managed+reuse",
                   help="extra sides for the GGUF model only (embedded prefix reuse has no MLX meaning)")
    p.add_argument("--out", default=str(REPO / "benchmarks" / "results" / "sdk-vs-serve.jsonl"))
    a = p.parse_args()
    if a.mlx_model:
        SKIP_ONESHOT_CONCURRENT[a.mlx_model] = True
    sc = script(a.max_tokens, a.context)
    script_path = Path(tempfile.mkdtemp()) / "script.json"
    script_path.write_text(json.dumps(sc))
    raw = str(Path(a.out).with_suffix(".sdk-raw.jsonl"))
    results, port = [], a.port
    for model in [m for m in (a.mlx_model, a.gguf_model) if m]:
        sides = a.sides.split(",") + (a.gguf_extra_sides.split(",") if model == a.gguf_model and a.gguf_extra_sides else [])
        for side in sides:
            h = bench.host_snapshot()
            if h["availableGB"] < 6:
                print(f"skip {side} {model}: only {h['availableGB']:.1f} GB available", file=sys.stderr)
                continue
            if side.startswith("sdk-"):
                rec = run_sdk(model, side.split("-", 1)[1], a.esh_home, str(script_path), raw)
            else:
                port += 1
                rec = run_serve(a.esh, model, a.esh_home, port, sc)
            if rec is None:
                print(f"{side} {model}: no result", file=sys.stderr)
                continue
            rec["config"] = side
            results.append(rec)
            print(json.dumps({k: v for k, v in rec.items() if k != "texts"})[:1800], flush=True)
            time.sleep(3)
    # Output equivalence: every configuration of a model must produce the same greedy text as the managed SDK run.
    for model in {r["model"] for r in results}:
        ref = next((r["texts"] for r in results if r["model"] == model and r["config"] == "sdk-managed"), None)
        for r in results:
            if r["model"] == model and ref is not None:
                r["identicalToSdkManaged"] = [x == y for x, y in zip(r.get("texts", []), ref)]
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    with Path(a.out).open("a") as f:
        for r in results:
            f.write(json.dumps({**r, "date": time.strftime("%Y-%m-%dT%H:%M:%S")}) + "\n")
    for r in results:
        print(r["config"], r["model"], "identical:", r.get("identicalToSdkManaged"))


if __name__ == "__main__":
    main()
