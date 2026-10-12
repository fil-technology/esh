#!/usr/bin/env python3
"""Run the quality suite against a running llama-server (OpenAI-compatible /v1/chat/completions).
Temperature 0 for determinism. Usage: run_http.py <base_url> <out_json> <model_label>"""
import sys, os, json, time, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import suite

base, out_json, label = sys.argv[1], sys.argv[2], sys.argv[3]


def chat(prompt, max_tokens):
    body = json.dumps({"messages": [{"role": "user", "content": prompt}], "temperature": 0,
                       "max_tokens": max_tokens, "seed": 42, "cache_prompt": False}).encode()
    req = urllib.request.Request(base + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=300) as r:
        j = json.loads(r.read())
    dt = time.perf_counter() - t0
    content = j["choices"][0]["message"]["content"]
    usage = j.get("usage", {})
    comp = usage.get("completion_tokens")
    tps = round(comp / dt, 2) if comp and dt > 0 else None
    return content, tps, comp

results = []
t_all = time.perf_counter()
for task in suite.TASKS:
    out, tps, n = chat(task["prompt"], task["max_tokens"])
    passed, detail = suite.score(task, out)
    results.append({"id": task["id"], "category": task["category"], "passed": bool(passed), "detail": detail,
                    "tokens": n, "gen_tps": tps, "output_head": out[:300]})
    print(f"[{'PASS' if passed else 'FAIL'}] {task['id']:22s} {detail[:50]}  ({tps} tps)", flush=True)

summary = {"model": label, "runtime": "llama-server (GGUF/Metal)", "label": "MEASURED", "temperature": 0,
           "wall_s": round(time.perf_counter() - t_all, 1),
           "passed": sum(r["passed"] for r in results), "total": len(results),
           "by_category": {}, "results": results}
for r in results:
    c = summary["by_category"].setdefault(r["category"], [0, 0]); c[1] += 1; c[0] += int(r["passed"])
json.dump(summary, open(out_json, "w"), indent=2)
print(f"\n{summary['passed']}/{summary['total']} passed | {summary['wall_s']}s")
print("by category:", {k: f"{v[0]}/{v[1]}" for k, v in summary["by_category"].items()})
