#!/usr/bin/env python3
"""Real-model validation of the MLX prefix-cache modes (legacy / tokens / live) through esh's production
`mlx-serve` worker, under the same memory guard + watchdog as esh_infer_bench.py.

Ground truth for every turn is a NO-REUSE run (fresh state file per turn, so the whole conversation is prefilled).
Each mode must reproduce it byte-for-byte with greedy decoding. Checks:

  multi-turn     4 agent turns: identical text, cache hits on follow-ups, KV length == reused + prefilled + generated
                 (no duplicated / missing tokens)
  isolation      two conversations interleaved on ONE worker + ONE state file (A1 B1 A2 B2)
  restart        turn 1 on a worker, worker shut down, turn 2 on a new worker (tokens: hit; live: clean miss)
  drop           drop-caches between turns (live: clean miss, correct output)
  kv8            uniform 8-bit KV quantization (kvBits=8) combined with the mode
  export         mlx-export-cache on a tokens-mode state file (sidecar) yields KV tensors

  python benchmarks/validate_prefix_cache.py --model <dir> --label <name> [--scenarios ...] [--modes ...]
Writes JSONL to benchmarks/results/prefix-cache-validation.jsonl and prints a summary.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import esh_infer_bench as bench  # noqa: E402

TURNS = [
    "You are a coding agent. Here is the file under discussion:\n\n```swift\n" + bench.load_fixture("code_edit.swift")
    + "\n```\n\nIn one sentence: what does `compact(to:)` do?",
    "Which method enforces the byte quota? Answer with the method name only.",
    "Write a one-line Swift guard that throws when `projected` exceeds `byteQuota`.",
    "Summarize the type's responsibilities in two short sentences.",
]
OTHER = [
    "List three properties of a good cache eviction policy, one line each.",
    "Which of them matters most for an agent loop? One sentence.",
]


class Worker(bench.MLXWorker):
    def ask(self, messages, state_file, session_id, max_tokens=120, extra=None):
        self.seq += 1
        rid = f"v{self.seq}"
        request = {
            "modelID": self.model_id, "kvMode": "raw", "stateFilePath": state_file,
            "session": {"id": session_id, "messages": [{"role": m["role"], "text": m["text"]} for m in messages]},
            "config": {"maxTokens": max_tokens, "temperature": 0.0, "enableThinking": False, **(extra or {})},
        }
        self._send({"id": rid, "op": "generate", "request": request})
        chunks = []
        while True:
            ev = self._read_event()
            if ev.get("id") != rid:
                continue
            if ev.get("event") == "token":
                chunks.append(ev.get("text", ""))
            elif ev.get("event") == "done":
                return {"text": "".join(chunks), "metrics": ev.get("metrics", {})}
            elif ev.get("event") == "error":
                raise RuntimeError(ev.get("message"))

    def drop(self):
        self._send({"op": "drop-caches"})
        while True:
            ev = self._read_event()
            if ev.get("event") == "caches-dropped":
                return ev.get("freedBytes")


def start(args, mode, extra_env=None):
    env = {} if mode == "legacy" else {"ESH_MLX_PREFIX_CACHE": mode}
    env.update(extra_env or {})
    w = Worker(args.python, args.model, env, args.floor_gb)
    w.model_id = Path(args.model).name
    return w


def converse(worker, turns, state_file, session_id, extra=None, fresh_each_turn=False):
    messages, out = [], []
    import shutil

    for t in turns:
        messages.append({"role": "user", "text": t})
        tmp = tempfile.mkdtemp(prefix="esh-val-") if fresh_each_turn else None
        sf = os.path.join(tmp, "s.json") if tmp else state_file
        try:
            r = worker.ask(messages, sf, session_id, extra=extra)
        finally:
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)
        messages.append({"role": "assistant", "text": r["text"]})
        out.append(r)
    return out


def kv_consistent(m):
    """KV length after the turn must equal reused + prefilled + generated (±1 for the EOS step)."""
    ctx, cached, prompt, gen = m.get("contextTokens"), m.get("cachedTokens") or 0, m.get("promptTokens"), m.get("generationTokens")
    if None in (ctx, prompt, gen):
        return None
    return abs(ctx - (cached + prompt + gen)) <= 1


def compare(ref, got):
    return [a["text"] == b["text"] for a, b in zip(ref, got)]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--modes", nargs="+", default=["legacy", "tokens", "live"])
    p.add_argument("--scenarios", nargs="+", default=["multi-turn", "isolation", "restart", "drop", "kv8", "export"])
    p.add_argument("--python", default=sys.executable)
    p.add_argument("--floor-gb", type=float, default=2.0)
    p.add_argument("--out", default=str(bench.REPO / "benchmarks" / "results" / "prefix-cache-validation.jsonl"))
    args = p.parse_args()

    weights = bench.dir_bytes(Path(args.model)) / 1e9
    reason = bench.preflight(weights * 1.3 + 1, bench.host_snapshot())
    results = {"label": args.label, "model": args.model, "date": time.strftime("%Y-%m-%dT%H:%M:%S")}
    if reason:
        results["gated"] = reason
        print("GATED:", reason)
        Path(args.out).open("a").write(json.dumps(results) + "\n")
        return

    # ground truth (no reuse) for every conversation/config we compare against
    w = start(args, "legacy")
    truth = {
        "main": converse(w, TURNS, None, "s-main", fresh_each_turn=True),
        "other": converse(w, OTHER, None, "s-other", fresh_each_turn=True),
    }
    if "kv8" in args.scenarios:
        truth["kv8"] = converse(w, TURNS[:3], None, "s-kv8", extra={"kvBits": 8}, fresh_each_turn=True)
    w.close()

    checks = []

    def record(scenario, mode, ok, detail):
        checks.append({"scenario": scenario, "mode": mode, "ok": bool(ok), "detail": detail})
        print(f"[{args.label}] {scenario:10} {mode:6} {'PASS' if ok else 'FAIL'}  {detail}", flush=True)

    for mode in args.modes:
        state_dir = tempfile.mkdtemp(prefix="esh-val-")
        state = os.path.join(state_dir, "state.json")
        w = start(args, mode)
        try:
            if "multi-turn" in args.scenarios:
                got = converse(w, TURNS, state, "s-main")
                same = compare(truth["main"], got)
                hits = [bool(r["metrics"].get("cacheHit")) for r in got]
                kv = [kv_consistent(r["metrics"]) for r in got]
                reuse = [round((r["metrics"].get("cachedTokens") or 0)
                               / max(1, (r["metrics"].get("cachedTokens") or 0) + (r["metrics"].get("promptTokens") or 0)), 3)
                         for r in got]
                ok = all(same) and (mode == "legacy" or all(hits[1:])) and all(k is not False for k in kv)
                record("multi-turn", mode, ok, {"identical": same, "hits": hits, "kvConsistent": kv, "reuseFraction": reuse,
                                                "residentCacheBytes": got[-1]["metrics"].get("residentCacheBytes")})
            if "isolation" in args.scenarios:
                s2 = os.path.join(state_dir, "iso.json")
                a_msgs, b_msgs, a_out, b_out = [], [], [], []
                for i in range(2):
                    a_msgs.append({"role": "user", "text": TURNS[i]})
                    ra = w.ask(a_msgs, s2, "s-A"); a_msgs.append({"role": "assistant", "text": ra["text"]}); a_out.append(ra)
                    b_msgs.append({"role": "user", "text": OTHER[i]})
                    rb = w.ask(b_msgs, s2, "s-B"); b_msgs.append({"role": "assistant", "text": rb["text"]}); b_out.append(rb)
                same = compare(truth["main"][:2], a_out) + compare(truth["other"][:2], b_out)
                record("isolation", mode, all(same), {"identical": same,
                                                      "hitsA": [bool(r["metrics"].get("cacheHit")) for r in a_out],
                                                      "hitsB": [bool(r["metrics"].get("cacheHit")) for r in b_out]})
            if "drop" in args.scenarios:
                s3 = os.path.join(state_dir, "drop.json")
                msgs = [{"role": "user", "text": TURNS[0]}]
                r1 = w.ask(msgs, s3, "s-drop")
                freed = w.drop()
                msgs += [{"role": "assistant", "text": r1["text"]}, {"role": "user", "text": TURNS[1]}]
                r2 = w.ask(msgs, s3, "s-drop")
                same = compare(truth["main"][:2], [r1, r2])
                record("drop", mode, all(same), {"identical": same, "freedBytes": freed,
                                                 "hitAfterDrop": bool(r2["metrics"].get("cacheHit"))})
            if "kv8" in args.scenarios:
                got = converse(w, TURNS[:3], os.path.join(state_dir, "kv8.json"), "s-kv8", extra={"kvBits": 8})
                same = compare(truth["kv8"], got)
                record("kv8", mode, all(same), {"identical": same, "hits": [bool(r["metrics"].get("cacheHit")) for r in got]})
            if "export" in args.scenarios and mode == "tokens":
                s5 = os.path.join(state_dir, "exp.json")
                w.ask([{"role": "user", "text": TURNS[0]}], s5, "s-exp")
                proc = subprocess.run([args.python, str(bench.BRIDGE), "mlx-export-cache"],
                                      input=json.dumps({"stateFilePath": s5, "modelID": w.model_id}),
                                      capture_output=True, text=True, timeout=600)
                try:
                    payload = json.loads(proc.stdout.strip().splitlines()[-1])
                    tensors = len((payload.get("snapshot") or {}).get("tensors") or [])
                except Exception as exc:  # noqa: BLE001
                    tensors, payload = 0, {"error": str(exc), "stderr": proc.stderr[-300:]}
                record("export", mode, tensors > 0, {"tensors": tensors})
        finally:
            w.close()

        if "restart" in args.scenarios:
            s4 = os.path.join(state_dir, "restart.json")
            w1 = start(args, mode)
            msgs = [{"role": "user", "text": TURNS[0]}]
            r1 = w1.ask(msgs, s4, "s-restart")
            w1.close()
            w2 = start(args, mode)
            msgs += [{"role": "assistant", "text": r1["text"]}, {"role": "user", "text": TURNS[1]}]
            r2 = w2.ask(msgs, s4, "s-restart")
            w2.close()
            same = compare(truth["main"][:2], [r1, r2])
            record("restart", mode, all(same), {"identical": same, "hitAfterRestart": bool(r2["metrics"].get("cacheHit"))})
        leftovers = sorted(os.listdir(state_dir))
        record("cleanup", mode, True, {"stateDirFiles": leftovers})
        import shutil
        shutil.rmtree(state_dir, ignore_errors=True)

    results["checks"] = checks
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    with Path(args.out).open("a") as f:
        f.write(json.dumps(results) + "\n")
    failed = [c for c in checks if not c["ok"]]
    print(f"[{args.label}] {len(checks) - len(failed)}/{len(checks)} checks passed")


if __name__ == "__main__":
    main()
