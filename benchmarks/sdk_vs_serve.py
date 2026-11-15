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

Provenance: by default both the SDK test bundle and the serve `esh` binary are built first (`--no-build` reuses them;
a binary older than its sources is refused unless `--allow-stale`). Every result line records the source commit and
dirty state, binary sha256s, toolchain, host, Python/MLX versions, bridge hash, model backend/repo/revision/weights,
the runtime settings of its side and the generation config.

Metrics per side: TTFT per turn, end-to-end per turn, session seconds, decode/prefill tok/s (when reported), cache hit
+ cached tokens, model load count, peak RSS (process + children), RSS after shutdown, leftover processes.

  python benchmarks/sdk_vs_serve.py --esh-home <store> --mlx-model <id> --gguf-model <id>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_provenance as prov_mod  # noqa: E402
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


def provenance(a, need_sdk: bool, need_serve: bool, models: list[str], script_path: Path) -> dict:
    """Build (unless --no-build) and identify everything that produces the numbers. Refuses stale binaries unless
    --allow-stale, so an old test build is never reused silently."""
    macos = REPO / "macos"
    root_sources = [REPO / "Sources", REPO / "Tests", REPO / "Package.swift", REPO / "Package.resolved"]
    serve_sources = root_sources[:1] + [REPO / "Package.swift", macos / "Sources", macos / "Package.swift",
                                        macos / "Package.resolved"]
    prov = {"date": time.strftime("%Y-%m-%dT%H:%M:%S"), "source": prov_mod.git_state(REPO),
            "toolchain": prov_mod.toolchain(), "host": prov_mod.host(), "python": prov_mod.python_runtime(),
            "bridge": prov_mod.file_identity(bench.BRIDGE),
            "workloadSha256": hashlib.sha256(script_path.read_bytes()).hexdigest(), "builds": []}
    default_esh = a.esh is None
    if need_sdk:
        if not a.no_build:
            prov["builds"].append(prov_mod.swift_build(REPO, ["--build-tests"]))
        test_binary = prov_mod.bin_path(REPO) / "EshLlamaCppTests.xctest" / "Contents" / "MacOS" / "EshLlamaCppTests"
        prov["sdkTestBinary"] = {**prov_mod.file_identity(test_binary), "builtThisRun": not a.no_build,
                                 **prov_mod.staleness(test_binary, root_sources)}
    if need_serve:
        if default_esh:
            if not a.no_build:
                prov["builds"].append(prov_mod.swift_build(macos, ["--product", "esh"]))
            a.esh = str(prov_mod.bin_path(macos) / "esh")
        esh = Path(a.esh)
        prov["serveBinary"] = {**prov_mod.file_identity(esh), "builtThisRun": default_esh and not a.no_build,
                               "version": prov_mod._run([str(esh), "version"]),
                               **(prov_mod.staleness(esh, serve_sources)
                                  if esh.resolve().is_relative_to(macos.resolve())
                                  else {"stale": None, "note": "binary outside this checkout: staleness unknown"})}
    stale = [k for k in ("sdkTestBinary", "serveBinary") if prov.get(k, {}).get("stale")]
    if stale and not a.allow_stale:
        raise SystemExit(f"refusing to benchmark stale binaries {stale} (older than their sources); rebuild, drop "
                         f"--no-build, or pass --allow-stale to record them as stale")
    store = Path(a.model_store or a.esh_home)
    prov["models"] = {m: prov_mod.model_identity(store, m) for m in models}
    return prov


def runtime_config(side: str, model: str, a) -> dict:
    """The runtime settings each side runs with (mirrors run_sdk / run_serve and SDKRuntimeBenchmark.swift)."""
    backend = "gguf" if model == a.gguf_model else "mlx"
    cfg = {"backend": backend, "prefixCacheEnv": os.environ.get("ESH_MLX_PREFIX_CACHE")}
    if side == "serve":
        cfg.update({"process": "esh serve", "ESH_MLX_PERSISTENT": "1", "stream": True,
                    "ggufServer": "llama-server" if backend == "gguf" else None})
    else:
        lifecycle = side.split("-", 1)[1]
        cfg.update({"process": "EshRuntime (swift test SDKRuntimeBenchmark/sdkSession)",
                    "lifecycle": lifecycle.replace("+reuse", ""),
                    "maxConcurrentRequests": 3 if lifecycle.startswith("managed") else None,
                    "mlxPersistentWorker": backend == "mlx" and lifecycle.startswith("managed"),
                    "ggufEmbedded": backend == "gguf", "ggufReusePromptPrefix": lifecycle.endswith("+reuse")})
    return cfg


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--esh", help="esh binary for the serve side (default: build macos/ and use its esh)")
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
    p.add_argument("--no-build", action="store_true",
                   help="use the existing SDK test build and esh binary instead of building them first")
    p.add_argument("--allow-stale", action="store_true",
                   help="with --no-build: run even if a binary is older than its sources (recorded as stale)")
    p.add_argument("--model-store", help="store whose models/manifests describe the models (default: --esh-home)")
    a = p.parse_args()
    if a.mlx_model:
        SKIP_ONESHOT_CONCURRENT[a.mlx_model] = True
    sc = script(a.max_tokens, a.context)
    script_dir = tempfile.TemporaryDirectory(prefix="esh-sdk-vs-serve-")   # removed when main() returns
    script_path = Path(script_dir.name) / "script.json"
    script_path.write_text(json.dumps(sc))
    models = [m for m in (a.mlx_model, a.gguf_model) if m]
    all_sides = set(a.sides.split(",")) | (set(a.gguf_extra_sides.split(",")) if a.gguf_model and a.gguf_extra_sides else set())
    prov = provenance(a, any(s.startswith("sdk-") for s in all_sides), "serve" in all_sides, models, script_path)
    print(json.dumps({"provenance": prov}, indent=1), flush=True)
    raw = str(Path(a.out).with_suffix(".sdk-raw.jsonl"))
    results, port = [], a.port
    for model in models:
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
            rec["modelIdentity"] = prov["models"].get(model)
            rec["generation"] = {"maxTokens": sc["maxTokens"], "temperature": 0, "contextTokens": sc["contextTokens"],
                                 "longTurns": len(sc["long"]), "concurrentConversations": len(sc["concurrent"]),
                                 "workloadSha256": prov["workloadSha256"]}
            rec["runtime"] = runtime_config(side, model, a)
            rec["provenance"] = prov
            results.append(rec)
            print(json.dumps({k: v for k, v in rec.items() if k not in ("texts", "provenance")})[:1800], flush=True)
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
