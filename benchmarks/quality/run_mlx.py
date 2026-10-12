#!/usr/bin/env python3
"""Run the quality suite against an MLX model (loaded once). Temperature 0 (greedy) for determinism.
Usage: run_mlx.py <hf_repo> <out_json>"""
import sys, os, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import os as _os, importlib as _il
suite = _il.import_module(_os.environ.get('ESH_SUITE','suite'))
import mlx.core as mx
from mlx_lm import load
from mlx_lm.sample_utils import make_sampler
try:
    from mlx_lm.generate import stream_generate
except Exception:
    from mlx_lm.utils import stream_generate

repo, out_json = sys.argv[1], sys.argv[2]
model, tok = load(repo)
sampler = make_sampler(temp=0.0)   # greedy
results = []
t_all = time.perf_counter()
for task in suite.TASKS:
    msgs = [{"role": "user", "content": task["prompt"]}]
    try:   # Qwen3 hybrid: disable thinking to match the Instruct 80B (fair like-for-like)
        text = tok.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False)
    except TypeError:
        text = tok.apply_chat_template(msgs, add_generation_prompt=True)
    t0 = time.perf_counter(); first = None; n = 0; chunks = []
    for r in stream_generate(model, tok, text, max_tokens=task["max_tokens"], sampler=sampler):
        if first is None: first = time.perf_counter()
        chunks.append(r.text); n += 1
    dt = time.perf_counter() - t0
    out = "".join(chunks)
    passed, detail = suite.score(task, out)
    gen_tps = round((n - 1) / (time.perf_counter() - first), 2) if first and n > 1 else None
    results.append({"id": task["id"], "category": task["category"], "passed": bool(passed), "detail": detail,
                    "ttft_s": round((first - t0), 2) if first else None, "tokens": n, "gen_tps": gen_tps,
                    "output_head": out[:300]})
    print(f"[{'PASS' if passed else 'FAIL'}] {task['id']:22s} {detail[:50]}  ({gen_tps} tps)", flush=True)

summary = {"model": repo, "runtime": "mlx-lm", "label": "MEASURED", "temperature": 0,
           "peak_memory_gb": round(mx.get_peak_memory() / 1e9, 2) if hasattr(mx, "get_peak_memory") else None,
           "wall_s": round(time.perf_counter() - t_all, 1),
           "passed": sum(r["passed"] for r in results), "total": len(results),
           "by_category": {}, "results": results}
for r in results:
    c = summary["by_category"].setdefault(r["category"], [0, 0]); c[1] += 1; c[0] += int(r["passed"])
json.dump(summary, open(out_json, "w"), indent=2)
print(f"\n{summary['passed']}/{summary['total']} passed | peak {summary['peak_memory_gb']} GB | {summary['wall_s']}s")
print("by category:", {k: f"{v[0]}/{v[1]}" for k, v in summary["by_category"].items()})
