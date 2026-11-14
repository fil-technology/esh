#!/usr/bin/env python3
"""Real `esh serve` integration test for the persistent-MLX prefix-cache modes (Phase 5).

For each variant it starts the esh binary's OpenAI-compatible server (ESH_MLX_PERSISTENT=1, plus the variant's
env), then over HTTP:
  1. an Ashex-shaped agent session (large fixed context + follow-ups), streamed: TTFT + end-to-end per turn
  2. two conversations issued CONCURRENTLY (threads): outputs must equal the baseline variant's serial outputs
  3. GET /v1/runtime: warm-pool status (resident models, resident session caches, budget)
and records host memory before/after and the server's peak RSS (process tree). The whole run is gated by the
same MemorySafetyPreflight port + watchdog as esh_infer_bench.py.

  python benchmarks/serve_integration.py --esh macos/.build/debug/esh --model qwen--qwen3-0.6b-mlx-8bit
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import esh_infer_bench as bench  # noqa: E402

CODE = bench.load_fixture("code_edit.swift")
TOOLS = bench.load_fixture("tool_context.md")
AGENT = [
    "You are a coding agent.\n\n```swift\n" + CODE + "\n```\n\n" + TOOLS + "\n\nIn one sentence, what does `compact(to:)` do?",
    "Which method would you change to fix the failing test? Method name only.",
    "Write the one-line fix for that method's guard.",
    "Does `append(_:to:)` enforce the quota before or after writing? One sentence.",
]
CONVO_B = [
    "List three properties of a good cache eviction policy, one line each.",
    "Which one matters most for an agent loop? One sentence.",
    "Give a one-line Swift doc comment for an LRU cache type.",
]


def tree_rss_gb(pid: int) -> float:
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,rss="], capture_output=True, text=True).stdout
    kids, rss = {}, {}
    for line in out.split("\n"):
        parts = line.split()
        if len(parts) == 3:
            p, pp, r = map(int, parts)
            kids.setdefault(pp, []).append(p)
            rss[p] = r
    total, stack = 0, [pid]
    while stack:
        p = stack.pop()
        total += rss.get(p, 0)
        stack.extend(kids.get(p, []))
    return total * 1024 / 1e9


class Server:
    def __init__(self, esh: str, port: int, env: dict):
        e = dict(os.environ)
        e.setdefault("ESH_MLX_VLM_BRIDGE", str(bench.BRIDGE))   # a dev build cannot locate the bridge by itself
        e.setdefault("ESH_PYTHON", sys.executable)               # ... nor esh's managed interpreter
        e.update(env)
        self.base = f"http://127.0.0.1:{port}"
        self.proc = subprocess.Popen([esh, "serve", "--port", str(port)], env=e,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                                     start_new_session=True)
        self.peak_rss = 0.0
        self._stop = threading.Event()
        threading.Thread(target=self._sample, daemon=True).start()
        for _ in range(120):
            try:
                urllib.request.urlopen(self.base + "/health", timeout=1)
                return
            except Exception:
                time.sleep(0.5)
        raise RuntimeError("esh serve did not become healthy")

    def _sample(self):
        while not self._stop.is_set():
            self.peak_rss = max(self.peak_rss, tree_rss_gb(self.proc.pid))
            h = bench.host_snapshot()
            if h["memoryCritical"] or h["availableGB"] < 2.0:
                self.tripped = f"watchdog: available {h['availableGB']:.1f} GB, pressure {h['pressureLevel']}"
                self.stop()
                return
            self._stop.wait(0.5)

    def chat(self, model, messages, max_tokens=120):
        body = json.dumps({"model": model, "messages": messages, "stream": True, "temperature": 0,
                           "max_tokens": max_tokens}).encode()
        req = urllib.request.Request(self.base + "/v1/chat/completions", data=body,
                                     headers={"Content-Type": "application/json"})
        t0, first, chunks = time.perf_counter(), None, []
        with urllib.request.urlopen(req, timeout=1800) as r:
            for raw in r:
                line = raw.decode().strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    obj = json.loads(data)
                except json.JSONDecodeError:
                    continue
                for ch in obj.get("choices", []) or []:
                    piece = (ch.get("delta") or {}).get("content")
                    if piece:
                        first = first or time.perf_counter()
                        chunks.append(piece)
        t1 = time.perf_counter()
        text = "".join(chunks)
        if text.lstrip().startswith("[error]"):
            raise RuntimeError(text.strip()[:300])
        return {"text": text, "ttft": (first - t0) if first else None, "e2e": t1 - t0}

    def runtime(self):
        with urllib.request.urlopen(self.base + "/v1/runtime", timeout=10) as r:
            return json.loads(r.read())

    def stop(self):
        self._stop.set()
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
            self.proc.wait(timeout=30)
        except Exception:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except Exception:
                pass


def converse(server, model, turns):
    msgs, out = [], []
    for t in turns:
        msgs.append({"role": "user", "content": t})
        r = server.chat(model, msgs)
        msgs.append({"role": "assistant", "content": r["text"]})
        out.append(r)
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--esh", default=str(bench.REPO / "macos" / ".build" / "debug" / "esh"))
    p.add_argument("--model", required=True)
    p.add_argument("--required-gb", type=float, default=2.0)
    p.add_argument("--port", type=int, default=18140)
    p.add_argument("--out", default=str(bench.REPO / "benchmarks" / "results" / "serve-integration.jsonl"))
    a = p.parse_args()

    reason = bench.preflight(a.required_gb, bench.host_snapshot())
    if reason:
        print("GATED:", reason)
        return
    variants = [("baseline", {"ESH_MLX_PERSISTENT": "1"}),
                ("tokens", {"ESH_MLX_PERSISTENT": "1", "ESH_MLX_PREFIX_CACHE": "tokens"}),
                ("live", {"ESH_MLX_PERSISTENT": "1", "ESH_MLX_PREFIX_CACHE": "live"})]
    results, reference = [], {}
    for i, (name, env) in enumerate(variants):
        before = bench.host_snapshot()
        server = Server(a.esh, a.port + i, env)
        try:
            agent = converse(server, a.model, AGENT)
            serial_b = converse(server, a.model, CONVO_B)
            # concurrent: agent session + conversation B at the same time (fresh copies, same prompts)
            box = {}
            ta = threading.Thread(target=lambda: box.__setitem__("a", converse(server, a.model, AGENT)))
            tb = threading.Thread(target=lambda: box.__setitem__("b", converse(server, a.model, CONVO_B)))
            t0 = time.perf_counter(); ta.start(); tb.start(); ta.join(); tb.join(); wall = time.perf_counter() - t0
            runtime = server.runtime()
            rec = {
                "variant": name, "model": a.model,
                "agentTTFT": [round(r["ttft"] or 0, 3) for r in agent],
                "agentE2E": [round(r["e2e"], 3) for r in agent],
                "agentSessionSeconds": round(sum(r["e2e"] for r in agent), 2),
                "concurrentWallSeconds": round(wall, 2),
                "serverPeakRssGB": round(server.peak_rss, 2),
                "hostAvailableBeforeGB": round(before["availableGB"], 2),
                "hostAvailableAfterGB": round(bench.host_snapshot()["availableGB"], 2),
                "runtime": runtime,
                "texts": {"agent": [r["text"] for r in agent], "b": [r["text"] for r in serial_b],
                          "concA": [r["text"] for r in box["a"]], "concB": [r["text"] for r in box["b"]]},
            }
            if name == "baseline":
                reference = rec["texts"]
            rec["identicalToBaseline"] = {k: [x == y for x, y in zip(reference[k], v)] for k, v in rec["texts"].items()}
            # concurrency must not change outputs within a variant either
            rec["concurrentEqualsSerial"] = {"a": rec["texts"]["concA"] == rec["texts"]["agent"],
                                             "b": rec["texts"]["concB"] == rec["texts"]["b"]}
            results.append(rec)
            print(f"[{name}] agent TTFT/turn={rec['agentTTFT']} session={rec['agentSessionSeconds']}s "
                  f"concurrent={rec['concurrentWallSeconds']}s peakRSS={rec['serverPeakRssGB']}GB "
                  f"cacheGB={runtime.get('residentCacheGB')} identical={rec['identicalToBaseline']} "
                  f"concurrent==serial={rec['concurrentEqualsSerial']}", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"[{name}] ABORTED: {getattr(server, 'tripped', None) or exc}", flush=True)
            results.append({"variant": name, "aborted": str(getattr(server, 'tripped', None) or exc)})
        finally:
            server.stop()
            time.sleep(2)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    with Path(a.out).open("a") as f:
        for r in results:
            f.write(json.dumps({**r, "date": time.strftime("%Y-%m-%dT%H:%M:%S")}) + "\n")


if __name__ == "__main__":
    main()
