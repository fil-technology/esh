#!/usr/bin/env python3
"""Summarize benchmarks/results/*.jsonl from esh_infer_bench.py: medians per (label, variant, workload), the change
vs the label's `baseline` variant (or --baseline-label), and whether outputs are byte-identical to that baseline.

  python benchmarks/summarize_bench.py [results.jsonl] [--labels a b] [--baseline-label X] [--markdown]
"""
from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

DEFAULT = Path(__file__).resolve().parent / "results" / "ghost-infer-study.jsonl"


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("path", nargs="?", default=str(DEFAULT))
    p.add_argument("--labels", nargs="*")
    p.add_argument("--baseline-label", help="compare every label against this label's `baseline` variant")
    p.add_argument("--markdown", action="store_true")
    a = p.parse_args()

    rows = [json.loads(l) for l in open(a.path) if l.strip()]
    groups = defaultdict(list)
    notes = []
    for r in rows:
        if a.labels and r["label"] not in a.labels and r["label"] != a.baseline_label:
            continue
        if "turns" not in r:
            notes.append(f"{r['label']}/{r['variant']}: {'GATED ' + r['gated'] if r.get('gated') else 'ABORTED ' + str(r.get('aborted'))}")
            continue
        groups[(r["label"], r["variant"], r["workload"])].append(r)

    def last(r, k):
        return r["turns"][-1].get(k)

    def total(r, k):
        return sum((t.get(k) or 0) for t in r["turns"])

    summary = {}
    for key, rs in groups.items():
        summary[key] = {
            "n": len(rs),
            "decode": med([last(r, "clientDecodeTps") for r in rs]),
            "ttft": med([last(r, "clientTtftS") for r in rs]),
            "ttftAll": med([sum(t.get("clientTtftS") or 0 for t in r["turns"]) for r in rs]),
            "e2e": med([total(r, "e2eS") for r in rs]),
            "prefill": med([last(r, "prefillTps") for r in rs]),
            "gen": med([total(r, "generationTokens") for r in rs]),
            "peak": med([last(r, "peakMetalGB") for r in rs]) or med([r.get("rssGB") for r in rs]),
            "hits": sum(1 for r in rs for t in r["turns"] if t.get("cacheHit")),
            "turns": sum(len(r["turns"]) for r in rs),
            "shas": [tuple(t["textSha"] for t in r["turns"]) for r in rs],
            "score": rs[-1]["turns"][-1].get("score"),
            "spec": rs[-1]["turns"][-1].get("speculative"),
        }

    def pct(new, old):
        if new is None or old is None or old == 0:
            return ""
        return f"{(new - old) / old * 100:+.0f}%"

    header = "| model | variant | workload | n | decode tok/s | Δ | TTFT s (last turn) | e2e s | Δ | prefill tok/s | gen tok | prefix hits | identical to baseline | quality |"
    print(header)
    print("|" + "---|" * 14)
    for (label, variant, workload), s in sorted(summary.items()):
        base_label = a.baseline_label or label
        b = summary.get((base_label, "baseline", workload))
        same = ""
        if b and (label, variant) != (base_label, "baseline"):
            same = f"{sum(1 for x in s['shas'] if x == b['shas'][0])}/{len(s['shas'])}"
        f = lambda x, d=2: "-" if x is None else f"{x:.{d}f}"
        q = ", ".join(f"{k}={v}" for k, v in (s["score"] or {}).items())
        print(f"| {label} | {variant} | {workload} | {s['n']} | {f(s['decode'],1)} | {pct(s['decode'], b and b['decode'])} | "
              f"{f(s['ttft'])} | {f(s['e2e'])} | {pct(s['e2e'], b and b['e2e'])} | {f(s['prefill'],0)} | {f(s['gen'],0)} | "
              f"{s['hits']}/{s['turns']} | {same} | {q} |")
    for n in notes:
        print(f"\n- {n}")


if __name__ == "__main__":
    main()
