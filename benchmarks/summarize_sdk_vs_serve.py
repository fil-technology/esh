#!/usr/bin/env python3
"""Markdown table from benchmarks/results/sdk-vs-serve.jsonl (latest record per model + configuration)."""
from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

path = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent / "results" / "sdk-vs-serve.jsonl")
latest: dict = {}
for line in path.read_text().splitlines():
    r = json.loads(line)
    latest[(r["model"], r["config"])] = r


def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return round(statistics.median(xs), 2) if xs else None


def fmt(v):
    return "—" if v is None else (f"{v}" if not isinstance(v, bool) else ("yes" if v else "no"))


rows = []
for (model, config), r in sorted(latest.items()):
    L = r.get("long", {})
    ttft = L.get("ttft", [])
    pool = r.get("pool") or {}
    residents = pool.get("residents") or []
    loads = sum(x.get("loadCount") or 0 for x in residents) if residents else ("1 per request" if config == "sdk-oneShot" else None)
    cached = L.get("cachedTokens")
    hit = (f"{sum(1 for c in cached[1:] if c)}/{len(cached) - 1}" if cached else "—")
    conc = r.get("concurrent", {})
    ident = r.get("identicalToSdkManaged")
    gen = L.get("generationTokens") or []
    rows.append([
        model, config, fmt(ttft[0] if ttft else None), fmt(med(ttft[1:])), fmt(L.get("sessionSeconds")),
        fmt(med(L.get("promptTokPerSec", []))), fmt(med(L.get("decodeTokPerSec", []))),
        hit, fmt(loads), "skipped" if conc.get("skipped") else fmt(conc.get("wallSeconds")),
        fmt(all(conc.get("equalsSerial", [])) if conc.get("equalsSerial") else None),
        fmt(r.get("peakRssGB")), fmt(r.get("rssAfterShutdownGB")),
        fmt(len(r.get("childProcessesAfterShutdown", r.get("orphansAfterStop", [])) or [])),
        f"{sum(ident)}/{len(ident)}" if ident else "—",
    ])

head = ["Model", "Config", "TTFT turn 1 (s)", "TTFT follow-ups, median (s)", "10-turn session (s)", "Prefill tok/s (median)",
        "Decode tok/s (median)", "Prefix-cache hits", "Model loads", "3 concurrent chats (s)", "Concurrent = serial",
        "Peak RSS (GB)", "RSS after shutdown (GB)", "Leftover processes", "Text = SDK managed"]
print("| " + " | ".join(head) + " |")
print("|" + "---|" * len(head))
for row in rows:
    print("| " + " | ".join(row) + " |")
