#!/usr/bin/env python3
"""esh inference benchmark — drives esh's PRODUCTION text paths under esh's memory-safety rules.

  * MLX  : the persistent `mlx-serve` worker in Tools/mlx_vlm_bridge.py (exactly what MLXPersistentRuntime speaks),
           including esh's prompt rendering, state-file prefix reuse and KV modes.
  * GGUF : `llama-server` started with the same arguments esh's LlamaServerProcess uses (+ optional extra flags
           under test), streamed over /v1/chat/completions like LlamaServerRuntime.

Guarding (never run a heavyweight model unguarded):
  1. Before every load: a port of `MemorySafetyPreflight.evaluate` (Sources/EshCore/Runtime/MemorySafetyPreflight.swift)
     on a live host snapshot (vm_stat available memory, memory-pressure level, internal-volume free space for swap).
     Gated -> the model is NOT loaded and the run records the reason.
  2. While running: a watchdog samples available memory + pressure every 0.5 s and KILLS the worker if available
     memory drops below --floor-gb or pressure turns critical. The run is recorded as aborted, never as a result.

Workloads are Ashex-shaped (agent turns), not synthetic token loops: short chat, whole-file code edit, JSON tool
call that echoes context, a growing multi-turn session, and long-context QA at fixed prompt sizes.

Usage:
  python benchmarks/esh_infer_bench.py mlx  --model <dir> --label <name> [--variant name:ENV=V,ENV=V ...]
  python benchmarks/esh_infer_bench.py gguf --model <file.gguf> --label <name> [--variant name:--flag,value ...]
Results append to --out (JSONL). Run with esh's managed interpreter (~/.esh/runtime/py311/venv/bin/python).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BRIDGE = REPO / "Tools" / "mlx_vlm_bridge.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"

# ----------------------------------------------------------------------------------------------- host + guard


def host_snapshot() -> dict:
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    page = int(re.search(r"page size of (\d+)", out).group(1)) if "page size of" in out else 16384

    def pages(name: str) -> int:
        m = re.search(rf"{name}:\s+(\d+)", out)
        return int(m.group(1)) if m else 0

    avail = (pages("Pages free") + pages("Pages inactive") + pages("Pages speculative") + pages("Pages purgeable")) * page
    total = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip())
    level = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], capture_output=True, text=True).stdout.strip()
    st = os.statvfs("/System/Volumes/Data")
    swap = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    used = re.search(r"used = ([\d.]+)M", swap)
    return {
        "totalGB": total / 1e9,
        "availableGB": avail / 1e9,
        "pressureLevel": int(level) if level.isdigit() else None,  # 1 normal, 2 warn, 4 critical
        "memoryCritical": level == "4",
        "systemVolumeFreeGB": st.f_bavail * st.f_frsize / 1e9,
        "swapUsedGB": (float(used.group(1)) / 1024) if used else None,
    }


def preflight(required_peak_gb: float, host: dict) -> str | None:
    """Port of MemorySafetyPreflight.evaluate. Returns a gating reason, or None when it fits."""
    if required_peak_gb < 4.0:
        return None
    total = host["totalGB"]
    if required_peak_gb > total * 0.98:
        return f"needs ~{required_peak_gb:.0f} GB, more than this Mac's {total:.0f} GB"
    avail = host["availableGB"] if host["availableGB"] is not None else total * 0.6
    if host["memoryCritical"] and required_peak_gb > total * 0.3:
        return "system memory pressure is critical"
    if required_peak_gb <= avail:
        return None
    deficit = required_peak_gb - avail
    if host["systemVolumeFreeGB"] < deficit + 3.0:
        return (f"needs ~{required_peak_gb:.1f} GB, only ~{avail:.1f} GB available and "
                f"~{host['systemVolumeFreeGB']:.1f} GB internal disk for swap")
    if deficit > total * 0.4:
        return f"would require heavy swapping (~{deficit:.0f} GB beyond available)"
    return None


class Watchdog(threading.Thread):
    def __init__(self, proc: subprocess.Popen, floor_gb: float):
        super().__init__(daemon=True)
        self.proc, self.floor_gb = proc, floor_gb
        self.min_avail_gb = 1e9
        self.max_pressure = 0
        self.max_swap_gb = 0.0
        self.tripped: str | None = None
        self._stop = threading.Event()

    def run(self):
        while not self._stop.is_set() and self.proc.poll() is None:
            h = host_snapshot()
            self.min_avail_gb = min(self.min_avail_gb, h["availableGB"])
            self.max_pressure = max(self.max_pressure, h["pressureLevel"] or 0)
            self.max_swap_gb = max(self.max_swap_gb, h["swapUsedGB"] or 0)
            reason = None
            if h["memoryCritical"]:
                reason = "memory pressure critical"
            elif h["availableGB"] < self.floor_gb:
                reason = f"available memory {h['availableGB']:.1f} GB < floor {self.floor_gb} GB"
            if reason:
                self.tripped = reason
                try:
                    self.proc.kill()
                except Exception:
                    pass
                return
            self._stop.wait(0.5)

    def stop(self):
        self._stop.set()


def dir_bytes(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and p.suffix in {".safetensors", ".gguf", ".bin"})


# ----------------------------------------------------------------------------------------------- workloads


def load_fixture(name: str) -> str:
    return (FIXTURES / name).read_text()


def filler(n_words: int) -> str:
    src = load_fixture("long_context.txt").split()
    out = []
    while len(out) < n_words:
        out.extend(src)
    return " ".join(out[:n_words])


def workloads(selected: list[str], contexts: list[int]) -> list[dict]:
    code = load_fixture("code_edit.swift")
    tools = load_fixture("tool_context.md")
    all_ = {
        "chat": [{
            "turns": ["In three sentences, explain why unified memory changes how a local LLM runtime should "
                      "decide where model weights live."],
            "max_tokens": 160,
        }],
        "code-edit": [{
            "turns": ["Rename the type `SessionStore` to `ConversationStore` everywhere in this file (including "
                      "comments and the doc comment), change nothing else, and reply with ONLY the complete updated "
                      "file in one ```swift block.\n\n```swift\n" + code + "\n```"],
            "max_tokens": 1600,
        }],
        "tool-json": [{
            "turns": [tools + "\n\nCall the `apply_patch` tool to fix the failing test described above. Reply with "
                      "ONLY a JSON object of the form {\"tool\": \"apply_patch\", \"arguments\": {\"path\": "
                      "string, \"old\": string, \"new\": string}} — `old` must be the exact current lines copied "
                      "from the file."],
            "max_tokens": 400,
            "json": True,
        }],
        "multi-turn": [{
            "turns": [
                "You are helping refactor a Swift package. First: list three risks of moving a model cache from "
                "an actor to a struct guarded by a lock. Be brief.",
                "Good. Now write the struct with a `get` and `put` API, under 25 lines.",
                "Add an LRU eviction with a byte budget. Show only the changed methods.",
                "Summarize the final design in two sentences.",
            ],
            "max_tokens": 200,
        }],
    }
    out = []
    for name in selected:
        if name.startswith("ctx"):
            continue
        for w in all_[name]:
            out.append({"name": name, **w})
    if "ctx" in selected:
        for n in contexts:
            words = int(n * 0.72)  # ~1.38 tokens/word for this English filler on Qwen/Llama BPEs
            out.append({
                "name": f"ctx-{n // 1024}k",
                "turns": ["Read the following notes, then answer the question at the end in one short paragraph.\n\n"
                          + filler(words) + "\n\nQuestion: according to the notes, what is the single most "
                          "important constraint on loading weights from an external SSD?"],
                "max_tokens": 96,
                "target_tokens": n,
            })
    return out


# ----------------------------------------------------------------------------------------------- MLX driver


class MLXWorker:
    def __init__(self, python: str, model: str, env_overrides: dict, floor_gb: float):
        env = dict(os.environ)
        env.update(env_overrides)
        env.setdefault("TOKENIZERS_PARALLELISM", "false")
        self.proc = subprocess.Popen([python, str(BRIDGE), "mlx-serve"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, bufsize=1)
        self.watchdog = Watchdog(self.proc, floor_gb)
        self.watchdog.start()
        self.stderr_tail: list[str] = []
        threading.Thread(target=self._drain_err, daemon=True).start()
        t0 = time.perf_counter()
        self._send({"op": "init", "modelPath": model, "modelID": Path(model).name})
        ready = self._read_event()
        if ready.get("event") != "ready":
            raise RuntimeError(f"worker failed to load: {ready} {''.join(self.stderr_tail[-5:])}")
        self.load_wall_s = time.perf_counter() - t0
        self.load_ms = ready.get("loadMs")
        self.seq = 0

    def _drain_err(self):
        for line in self.proc.stderr:
            self.stderr_tail.append(line)
            del self.stderr_tail[:-50]

    def _send(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _read_event(self) -> dict:
        while True:
            line = self.proc.stdout.readline()
            if not line:
                reason = self.watchdog.tripped or "".join(self.stderr_tail[-5:]) or "worker exited"
                raise RuntimeError(f"worker died: {reason}")
            line = line.strip()
            if line.startswith("{"):
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    continue

    def generate(self, messages: list[dict], state_file: str, max_tokens: int, config_extra: dict) -> dict:
        self.seq += 1
        rid = f"r{self.seq}"
        request = {
            "modelID": "bench",
            "session": {"messages": [{"role": m["role"], "text": m["text"]} for m in messages]},
            "stateFilePath": state_file,
            "kvMode": "raw",
            "config": {"maxTokens": max_tokens, "temperature": 0.0, "enableThinking": False, **config_extra},
        }
        t0 = time.perf_counter()
        self._send({"id": rid, "op": "generate", "request": request})
        first = None
        chunks = []
        while True:
            ev = self._read_event()
            if ev.get("id") != rid:
                continue
            if ev.get("event") == "token":
                if first is None:
                    first = time.perf_counter()
                chunks.append(ev.get("text", ""))
            elif ev.get("event") == "done":
                t1 = time.perf_counter()
                m = ev.get("metrics", {})
                gen = m.get("generationTokens") or 0
                return {
                    "text": "".join(chunks),
                    "clientTtftS": (first - t0) if first else None,
                    "e2eS": t1 - t0,
                    # client-side decode rate: tokens after the first over the streaming window
                    "clientDecodeTps": ((gen - 1) / (t1 - first)) if first and gen > 1 and t1 > first else None,
                    "workerTtftS": (m.get("ttftMilliseconds") or 0) / 1000 or None,
                    "workerDecodeTps": m.get("tokensPerSecond"),
                    "promptTokens": m.get("promptTokens"),
                    "contextTokens": m.get("contextTokens"),
                    "generationTokens": gen,
                    "cacheHit": m.get("cacheHit"),
                    "cachedTokens": m.get("cachedTokens"),
                    "peakMetalGB": (m.get("memoryBytes") or 0) / 1e9,
                    "finishReason": m.get("finishReason"),
                    "speculative": m.get("speculative"),
                    "prefillTps": (m.get("promptTokens") / (m.get("ttftMilliseconds") / 1000))
                    if m.get("promptTokens") and m.get("ttftMilliseconds") else None,
                }
            elif ev.get("event") == "error":
                raise RuntimeError(ev.get("message"))

    def close(self):
        self.watchdog.stop()
        try:
            self._send({"op": "shutdown"})
            self.proc.stdin.close()
            self.proc.wait(timeout=30)
        except Exception:
            self.proc.kill()


# ----------------------------------------------------------------------------------------------- GGUF driver


class LlamaServer:
    def __init__(self, binary: str, model: str, extra_args: list[str], floor_gb: float, port: int, ctx: int):
        # Mirrors macos/Sources/EshMacRuntime/Backends/GGUF/LlamaServerProcess.swift (-m -c -ngl 999 -np 1
        # --host --port --reasoning-format none ...) plus the flags under test.
        args = [binary, "-m", model, "-c", str(ctx), "-ngl", "999", "-np", "1", "--host", "127.0.0.1",
                "--port", str(port), "--jinja", "--reasoning-format", "none", "--no-webui"] + extra_args
        self.base = f"http://127.0.0.1:{port}"
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.stderr_tail: list[str] = []
        threading.Thread(target=self._drain, daemon=True).start()
        self.watchdog = Watchdog(self.proc, floor_gb)
        self.watchdog.start()
        t0 = time.perf_counter()
        while True:
            if self.proc.poll() is not None:
                raise RuntimeError("llama-server exited: " + "".join(self.stderr_tail[-8:]))
            try:
                with urllib.request.urlopen(self.base + "/health", timeout=1) as r:
                    if r.status == 200:
                        break
            except Exception:
                pass
            if time.perf_counter() - t0 > 600:
                raise RuntimeError("llama-server load timeout")
            time.sleep(0.25)
        self.load_wall_s = time.perf_counter() - t0
        self.load_ms = None

    def _drain(self):
        for line in self.proc.stderr:
            self.stderr_tail.append(line)
            del self.stderr_tail[:-80]

    def generate(self, messages: list[dict], state_file: str, max_tokens: int, config_extra: dict) -> dict:
        body = {
            "messages": [{"role": m["role"], "content": m["text"]} for m in messages],
            "stream": True, "max_tokens": max_tokens, "temperature": 0.0, "cache_prompt": True,
            "timings_per_token": False, "chat_template_kwargs": {"enable_thinking": False},
        }
        req = urllib.request.Request(self.base + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        t0 = time.perf_counter()
        first = None
        chunks = []
        timings = {}
        with urllib.request.urlopen(req, timeout=1800) as r:
            for raw in r:
                line = raw.decode().strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                obj = json.loads(data)
                if obj.get("timings"):
                    timings = obj["timings"]
                for ch in obj.get("choices", []):
                    piece = (ch.get("delta") or {}).get("content")
                    if piece:
                        if first is None:
                            first = time.perf_counter()
                        chunks.append(piece)
        t1 = time.perf_counter()
        gen = timings.get("predicted_n") or 0
        return {
            "text": "".join(chunks),
            "clientTtftS": (first - t0) if first else None,
            "e2eS": t1 - t0,
            "clientDecodeTps": ((gen - 1) / (t1 - first)) if first and gen > 1 and t1 > first else None,
            "workerTtftS": (timings.get("prompt_ms") or 0) / 1000 or None,
            "workerDecodeTps": timings.get("predicted_per_second"),
            "prefillTps": timings.get("prompt_per_second"),
            "promptTokens": timings.get("prompt_n"),
            "cachedTokens": timings.get("cache_n"),
            "generationTokens": gen,
            "speculative": ({"drafted": timings.get("draft_n"), "accepted": timings.get("draft_n_accepted")}
                            if timings.get("draft_n") is not None else None),
        }

    def rss_gb(self) -> float | None:
        try:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(self.proc.pid)], capture_output=True, text=True).stdout
            return int(out.strip()) * 1024 / 1e9
        except Exception:
            return None

    def close(self):
        self.watchdog.stop()
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=30)
        except Exception:
            self.proc.kill()


# ----------------------------------------------------------------------------------------------- scoring


def score(workload: dict, text: str) -> dict:
    s = {}
    if workload["name"] == "code-edit":
        body = text.split("```swift", 1)[-1].split("```", 1)[0] if "```" in text else text
        s["renamedEverywhere"] = "SessionStore" not in body and "ConversationStore" in body
        s["lengthRatio"] = round(len(body.strip()) / max(1, len(load_fixture("code_edit.swift").strip())), 3)
    if workload.get("json"):
        candidate = text.strip()
        if "```" in candidate:
            candidate = candidate.split("```", 2)[1].removeprefix("json").strip()
        try:
            obj = json.loads(candidate[candidate.index("{"): candidate.rindex("}") + 1])
            s["jsonValid"] = True
            args = obj.get("arguments", {})
            s["toolCallValid"] = obj.get("tool") == "apply_patch" and all(isinstance(args.get(k), str) for k in ("path", "old", "new"))
            s["oldIsVerbatim"] = bool(args.get("old")) and args.get("old") in load_fixture("tool_context.md")
        except Exception:
            s["jsonValid"] = False
            s["toolCallValid"] = False
    if workload["name"].startswith("ctx"):
        s["mentionsBandwidth"] = bool(re.search(r"bandwidth|GB/s|throughput|slow", text, re.I))
    return s


# ----------------------------------------------------------------------------------------------- main


def run(args):
    model = Path(args.model)
    weights_gb = dir_bytes(model) / 1e9
    max_ctx = max(args.contexts) if "ctx" in args.workloads else 8192
    required = weights_gb * 1.3 + args.kv_gb_per_k * max_ctx / 1024
    variants = []
    for v in args.variant or ["baseline:"]:
        name, _, spec = v.partition(":")
        variants.append((name, spec))
    work = workloads(args.workloads, args.contexts)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    meta = {
        "label": args.label, "backend": args.backend, "model": str(model), "weightsGB": round(weights_gb, 2),
        "requiredPeakGB": round(required, 2), "runs": args.runs, "date": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    for vname, spec in variants:
        host = host_snapshot()
        reason = preflight(required, host)
        rec_base = {**meta, "variant": vname, "variantSpec": spec, "hostBefore": host}
        if reason:
            print(f"[{args.label}/{vname}] GATED: {reason}", flush=True)
            with out_path.open("a") as f:
                f.write(json.dumps({**rec_base, "gated": reason}) + "\n")
            continue
        engine = None
        try:
            if args.backend == "mlx":
                env = dict(kv.split("=", 1) for kv in spec.split(",") if "=" in kv)
                engine = MLXWorker(args.python, str(model), env, args.floor_gb)
            else:
                extra = [a for a in spec.split(",") if a]
                engine = LlamaServer(args.llama_server, str(model), extra, args.floor_gb, args.port, args.ctx)
            print(f"[{args.label}/{vname}] loaded in {engine.load_wall_s:.1f}s", flush=True)
            for w in work:
                for run_i in range(args.runs + (1 if args.warmup else 0)):
                    state_dir = tempfile.mkdtemp(prefix="esh-bench-")
                    state_file = os.path.join(state_dir, "state.json")
                    messages: list[dict] = []
                    turn_results = []
                    try:
                        for turn in w["turns"]:
                            messages.append({"role": "user", "text": turn})
                            r = engine.generate(messages, state_file, w["max_tokens"], {})
                            messages.append({"role": "assistant", "text": r["text"]})
                            r["score"] = score(w, r["text"])
                            turn_results.append(r)
                    finally:
                        shutil.rmtree(state_dir, ignore_errors=True)
                    if args.warmup and run_i == 0:
                        continue
                    rec = {**rec_base, "workload": w["name"], "run": run_i, "turns": [
                        {k: v for k, v in t.items() if k != "text"} | {"textHead": t["text"][:160], **({"text": t["text"]} if args.keep_text else {}),
                                                                        "textSha": _sha(t["text"])}
                        for t in turn_results],
                        "loadWallS": engine.load_wall_s,
                        "rssGB": engine.rss_gb() if hasattr(engine, "rss_gb") else None,
                        "watchdog": {"minAvailGB": round(engine.watchdog.min_avail_gb, 2),
                                     "maxPressure": engine.watchdog.max_pressure,
                                     "maxSwapGB": round(engine.watchdog.max_swap_gb, 2)}}
                    with out_path.open("a") as f:
                        f.write(json.dumps(rec) + "\n")
                    last = turn_results[-1]
                    print(f"[{args.label}/{vname}] {w['name']} run{run_i}: ttft={_f(last['clientTtftS'])}s "
                          f"decode={_f(last['clientDecodeTps'])} tok/s e2e={_f(last['e2eS'])}s "
                          f"gen={last['generationTokens']} spec={last.get('speculative')} {last['score']}", flush=True)
        except Exception as exc:  # noqa: BLE001
            reason = engine.watchdog.tripped if engine and engine.watchdog.tripped else str(exc)
            print(f"[{args.label}/{vname}] ABORTED: {reason}", flush=True)
            with out_path.open("a") as f:
                f.write(json.dumps({**rec_base, "aborted": reason}) + "\n")
        finally:
            if engine:
                engine.close()
            time.sleep(2)


def _sha(text: str) -> str:
    import hashlib
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def _f(x):
    return "-" if x is None else f"{x:.2f}"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("backend", choices=["mlx", "gguf"])
    p.add_argument("--model", required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--variant", action="append", help="name:SPEC (mlx: ENV=V,ENV=V ; gguf: --flag,value,--flag)")
    p.add_argument("--workloads", nargs="+", default=["chat", "code-edit", "tool-json", "multi-turn"])
    p.add_argument("--contexts", nargs="+", type=int, default=[1024, 8192])
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--warmup", action="store_true", default=True)
    p.add_argument("--no-warmup", dest="warmup", action="store_false")
    p.add_argument("--floor-gb", type=float, default=2.0)
    p.add_argument("--kv-gb-per-k", type=float, default=0.1, help="KV estimate per 1K tokens for the guard")
    p.add_argument("--python", default=sys.executable)
    p.add_argument("--llama-server", default=os.environ.get("ESH_LLAMA_CPP_SERVER", "/opt/homebrew/bin/llama-server"))
    p.add_argument("--port", type=int, default=18087)
    p.add_argument("--ctx", type=int, default=8192)
    p.add_argument("--keep-text", action="store_true", help="store full outputs (for divergence analysis)")
    p.add_argument("--out", default=str(REPO / "benchmarks" / "results" / "ghost-infer-study.jsonl"))
    run(p.parse_args())


if __name__ == "__main__":
    main()
