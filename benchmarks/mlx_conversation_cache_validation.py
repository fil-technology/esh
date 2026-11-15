#!/usr/bin/env python3
"""Conversation-aware MLX prefix cache: validation + regression (issue #38), through `esh serve` + the persistent worker.

  python benchmarks/mlx_conversation_cache_validation.py --esh macos/.build/debug/esh --esh-home <store> \
      --out results.json [--baseline-bridge <older Tools/mlx_vlm_bridge.py>] [--switch-model <second model id>]

Covers: serial vs concurrent (hit rate, reused tokens, TTFT, wall time, memory), more conversations than slots, a byte
budget, two streams on the same conversation, cancellation, model switching, restart, memory pressure (the worker's
critical signal, simulated by a flag file) and cross-conversation canary isolation. Text is compared, but
byte-identical output is not required where reuse vs full prefill can flip greedy near-ties (see #38).

Every request: temperature 0, top_p 1, seed 0, enable_thinking false, max_tokens 64 (issue #38 controls), streamed so
TTFT is measured client-side. Worker metrics (cachedTokens, prefixCacheSource, finishReason, residentCacheBytes, slots)
come from the worker's own `done` events, teed by probe_bridge.py. "old" = origin/main's bridge (shared-state
behaviour: content-matched slots, 2 slots); "new" = this branch's bridge.
"""
import argparse
import json
import os
import sys
import tempfile
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from serve_integration import AGENT, CONVO_B, Server  # noqa: E402
from serve_live_validation import CONVO_C  # noqa: E402

_p = argparse.ArgumentParser()
_p.add_argument("--esh", required=True)
_p.add_argument("--esh-home", required=True)
_p.add_argument("--out", required=True)
_p.add_argument("--model", default="qwen--qwen3-0.6b-mlx-8bit")
_p.add_argument("--switch-model", default="qwen2.5-0.5b-instruct-q4km", help="second model for the switching test")
_p.add_argument("--baseline-bridge", help="an older bridge to compare against (e.g. from `git archive origin/main Tools`)")
ARGS = _p.parse_args()
ESH, HOME, OUT = ARGS.esh, ARGS.esh_home, ARGS.out
MODEL = ARGS.model
BIG = ARGS.switch_model
MAX_TOKENS = 64
CONVOS = {"agent": AGENT, "b": CONVO_B, "c": CONVO_C}
BRIDGES = {"old": ARGS.baseline_bridge, "new": os.path.join(REPO, "Tools", "mlx_vlm_bridge.py")}
_SCRATCH = tempfile.TemporaryDirectory(prefix="esh-convcache-")   # event log + pressure flag; removed at exit
LOG = os.path.join(_SCRATCH.name, "probe-events.jsonl")
FLAG = os.path.join(_SCRATCH.name, "pressure.flag")
PORT = [19500]


def server(variant, env=None):
    PORT[0] += 1
    if os.path.exists(LOG):
        os.remove(LOG)
    return Server(ESH, PORT[0], {"ESH_MLX_PERSISTENT": "1", "ESH_HOME": HOME,
                                 "ESH_MLX_VLM_BRIDGE": os.path.join(HERE, "mlx_probe_bridge.py"),
                                 "PROBE_BRIDGE": BRIDGES[variant], "PROBE_LOG": LOG,
                                 "PROBE_PRESSURE_FLAG": FLAG, **(env or {})})


def events():
    if not os.path.exists(LOG):
        return []
    return [json.loads(line) for line in open(LOG)]


def chat(s, messages, model=MODEL, cancel_after=None, key=None):
    body = {"model": model, "messages": messages, "stream": True, "temperature": 0, "top_p": 1, "seed": 0,
            "enable_thinking": False, "max_tokens": MAX_TOKENS}
    if key:
        body["prompt_cache_key"] = key
    req = urllib.request.Request(s.base + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0, first, parts = time.perf_counter(), None, []
    r = urllib.request.urlopen(req, timeout=900)
    try:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line[5:].strip() == "[DONE]":
                continue
            try:
                obj = json.loads(line[5:])
            except json.JSONDecodeError:
                continue
            for ch in obj.get("choices") or []:
                piece = (ch.get("delta") or {}).get("content")
                if piece:
                    first = first or time.perf_counter()
                    parts.append(piece)
            if cancel_after and len(parts) >= cancel_after:
                break
    finally:
        r.close()
    end = time.perf_counter()
    return {"text": "".join(parts), "ttft": round((first - t0), 4) if first else None,
            "e2e": round(end - t0, 4), "_end": end}


def converse(s, name, turns, log, model=MODEL, key=None):
    msgs, out = [], []
    for i, t in enumerate(turns):
        msgs.append({"role": "user", "content": t})
        r = chat(s, msgs, model=model, key=key)
        log.append((name, i, r))
        msgs.append({"role": "assistant", "content": r["text"]})
        out.append(r["text"])
    return out


def run_pass(s, convos, concurrent, key_prefix=None, same_key=None):
    log, box = [], {}
    if same_key:   # every conversation sends the SAME caller key (two clients aliasing one key)
        key_prefix = None
    t0 = time.perf_counter()
    if concurrent:
        ths = [threading.Thread(target=lambda n=n, t=t: box.__setitem__(
            n, converse(s, n, t, log, key=same_key or (f"{key_prefix}-{n}" if key_prefix else None))))
            for n, t in convos.items()]
        [th.start() for th in ths]
        [th.join() for th in ths]
    else:
        for n, t in convos.items():
            box[n] = converse(s, n, t, log, key=f"{key_prefix}-{n}" if key_prefix else None)
    return box, log, round(time.perf_counter() - t0, 3)


def summarize(log, done):
    rows = []
    for (name, turn, r), e in zip(log, done):
        m = e.get("metrics", {})
        rows.append({"req": f"{name}[{turn}]", "ttft": r["ttft"], "e2e": r["e2e"], "cachedTokens": m.get("cachedTokens"),
                     "promptTokens": m.get("promptTokens"), "source": m.get("prefixCacheSource"),
                     "slots": m.get("liveCacheSlots"), "residentCacheBytes": m.get("residentCacheBytes"),
                     "finishReason": m.get("finishReason")})
    hits = [x for x in rows if (x["cachedTokens"] or 0) > 0]
    later = [x for x in rows if not x["req"].endswith("[0]")]
    return {"requests": rows, "hitRateLaterTurns": round(len([x for x in later if x in hits]) / max(1, len(later)), 3),
            "reusedTokens": sum(x["cachedTokens"] or 0 for x in rows),
            "promptTokens": sum(x["promptTokens"] or 0 for x in rows),
            "meanTTFTLaterTurns": round(sum(x["ttft"] or 0 for x in later) / max(1, len(later)), 4)}


def timed_pass(s, convos, concurrent, key_prefix=None, same_key=None):
    """Run a pass and attach worker metrics. Client log order is completion order of each request's response."""
    before = len([e for e in events() if e["event"] == "done"])
    box, log, wall = run_pass(s, convos, concurrent, key_prefix, same_key)
    done = [e for e in events() if e["event"] == "done"][before:]
    # sort client log by completion time so it lines up with the worker's sequential done events
    log_sorted = sorted(log, key=lambda x: x[2]["_end"]) if log and "_end" in log[0][2] else log
    return box, summarize(log_sorted, done), wall


def tree_rss(s):
    from serve_integration import tree_rss_gb
    return round(tree_rss_gb(s.proc.pid), 3)


def main():
    res = {"model": MODEL, "maxTokens": MAX_TOKENS}

    # E1 + E2 + E3: the #38 experiment, old vs new, plus over-capacity and byte-budget variants
    variants = {"new": ("new", {}), "new-slots2": ("new", {"ESH_MLX_LIVE_PREFIX_SLOTS": "2"}),
                "new-budget120MB": ("new", {"ESH_MLX_LIVE_PREFIX_MAX_BYTES": "120000000"})}
    if BRIDGES["old"]:
        variants = {"old": ("old", {}), **variants}
    for label, (variant, env) in variants.items():
        s = server(variant, env)
        try:
            out = {}
            for phase, conc in (("serial1", False), ("concurrent", True), ("serial2", False)):
                box, summ, wall = timed_pass(s, CONVOS, conc)
                out[phase] = {"texts": box, "wallSeconds": wall, **summ}
            rt = s.runtime().get("residents", [])
            out["steady"] = {"treeRssGB": tree_rss(s), "peakTreeRssGB": round(s.peak_rss, 3),
                             "pool": [{k: r.get(k) for k in ("modelID", "residentCacheBytes", "loadCount")} for r in rt]}
        finally:
            s.stop()
            time.sleep(2)
        res[label] = out
        print(label, {p: (out[p]["wallSeconds"], out[p]["hitRateLaterTurns"], out[p]["reusedTokens"])
                      for p in ("serial1", "concurrent", "serial2")}, flush=True)

    # E4: two concurrent requests streams for the SAME conversation
    s = server("new")
    try:
        log, box = [], {}
        ths = [threading.Thread(target=lambda i=i: box.__setitem__(i, converse(s, f"b#{i}", CONVO_B, log)))
               for i in range(2)]
        [t.start() for t in ths]
        [t.join() for t in ths]
        done = [e for e in events() if e["event"] == "done"]
        res["sameConversationConcurrent"] = {
            "texts": box, "identicalAcrossStreams": [a == b for a, b in zip(box[0], box[1])],
            "errors": [e for e in events() if e["event"] == "error"],
            "worker": [(e["metrics"].get("cachedTokens"), e["metrics"].get("prefixCacheSource")) for e in done]}
    finally:
        s.stop()
        time.sleep(2)
    print("same-conversation", res["sameConversationConcurrent"]["identicalAcrossStreams"], flush=True)

    # E5: cancellation mid-generation, then continue the conversation
    s = server("new")
    try:
        msgs = [{"role": "user", "content": AGENT[0]}]
        partial = chat(s, msgs, cancel_after=5)
        time.sleep(1.5)
        msgs += [{"role": "assistant", "content": partial["text"]}, {"role": "user", "content": AGENT[1]}]
        nxt = chat(s, msgs)
        evs = events()
        res["cancellation"] = {"partialText": partial["text"], "next": nxt["text"],
                               "worker": [(e["event"], e.get("metrics", {}).get("finishReason"),
                                           e.get("metrics", {}).get("cachedTokens"),
                                           e.get("metrics", {}).get("prefixCacheSource")) for e in evs if e["event"] != "ready"]}
    finally:
        s.stop()
        time.sleep(2)
    s = server("new")
    try:
        res["cancellation"]["nextOnFreshServer"] = chat(s, msgs)["text"]
    finally:
        s.stop()
        time.sleep(2)
    print("cancellation", res["cancellation"]["worker"], flush=True)

    # E6: model switching (a second MLX model, its own worker) in the middle of a conversation; E7: restart
    s = server("new")
    try:
        log = []
        hist = [{"role": "user", "content": CONVO_C[0]}]
        a0 = chat(s, hist)
        hist += [{"role": "assistant", "content": a0["text"]}, {"role": "user", "content": CONVO_C[1]}]
        big = chat(s, [{"role": "user", "content": CONVO_C[0]}], model=BIG)
        a1 = chat(s, hist)
        rt = s.runtime().get("residents", [])
        evs = [e for e in events() if e["event"] == "done"]
        res["modelSwitch"] = {"worker": [(e["metrics"].get("cachedTokens"), e["metrics"].get("prefixCacheSource"))
                                         for e in evs], "residents": [r.get("modelID") for r in rt],
                              "switchModelReply": big["text"][:80]}
        hist += [{"role": "assistant", "content": a1["text"]}, {"role": "user", "content": CONVO_C[2]}]
    finally:
        s.stop()
        time.sleep(2)
    s = server("new")
    try:
        r1 = chat(s, hist)
        hist2 = hist + [{"role": "assistant", "content": r1["text"]}, {"role": "user", "content": CONVO_C[3]}]
        chat(s, hist2)
        evs = [e for e in events() if e["event"] == "done"]
        res["restart"] = {"worker": [(e["metrics"].get("cachedTokens"), e["metrics"].get("prefixCacheSource"))
                                     for e in evs]}
    finally:
        s.stop()
        time.sleep(2)
    print("model switch", res["modelSwitch"]["worker"], "restart", res["restart"]["worker"], flush=True)

    # E8: memory pressure (worker's critical signal) during a turn
    s = server("new")
    try:
        hist = [{"role": "user", "content": CONVO_B[0]}]
        r0 = chat(s, hist)
        hist += [{"role": "assistant", "content": r0["text"]}, {"role": "user", "content": CONVO_B[1]}]
        open(FLAG, "w").close()
        r1 = chat(s, hist)
        os.remove(FLAG)
        hist += [{"role": "assistant", "content": r1["text"]}, {"role": "user", "content": CONVO_B[2]}]
        chat(s, hist)
        evs = [e for e in events() if e["event"] == "done"]
        res["pressure"] = {"worker": [(e["metrics"].get("finishReason"), e["metrics"].get("cachedTokens"),
                                       e["metrics"].get("prefixCacheSource"), e["metrics"].get("liveCacheSlots"))
                                      for e in evs]}
    finally:
        if os.path.exists(FLAG):
            os.remove(FLAG)
        s.stop()
        time.sleep(2)
    print("pressure", res["pressure"]["worker"], flush=True)

    # E9: canary isolation (issue #38 regression), new bridge, default slots, plus explicit prompt_cache_key
    canaries = ["AMBER-FALCON-7", "COBALT-ORCHID-3", "DELTA-MARMOT-9"]
    shared_ctx = "You are a coding agent.\n\n```swift\n" + AGENT[0].split("```swift\n", 1)[1].split("\n```", 1)[0] + "\n```\n\n"
    res["canary"] = []
    for shared in (True, False):
        for mode in ("derived", "explicit"):
            for rep in range(3 if mode == "derived" else 1):
                convos = {f"c{i}": [(shared_ctx if shared else "") + f"Remember this: my project codename is {c}. "
                                    "Acknowledge in one short sentence.",
                                    "Give one tip for naming Swift variables. One sentence.",
                                    "What is my project codename? Reply with only the codename.",
                                    "Repeat my project codename once more, exactly."] for i, c in enumerate(canaries)}
                s = server("new")
                try:
                    box, summ, _ = timed_pass(s, convos, True, key_prefix="canary" if mode == "explicit" else None)
                finally:
                    s.stop()
                    time.sleep(2)
                leaks = [(i, t, txt) for i, c in enumerate(canaries) for t, txt in enumerate(box[f"c{i}"])
                         if any(o.split("-")[0] in txt.upper() for o in canaries if o != c)]
                recall = [canaries[i].lower() in box[f"c{i}"][2].lower() for i in range(3)]
                res["canary"].append({"sharedPrefix": shared, "identity": mode, "rep": rep, "leaks": leaks,
                                      "recall": recall, "hitRateLaterTurns": summ["hitRateLaterTurns"],
                                      "sources": [x["source"] for x in summ["requests"]]})
                print("canary", shared, mode, rep, "leaks", len(leaks), "recall", recall,
                      "hit", summ["hitRateLaterTurns"], flush=True)
    # E10: identical OPENING, different private histories -> the conversations share an identity (derived), or all
    # send one caller key. Reuse must stay an exact-prefix optimization: no canary may cross over, and each
    # conversation's output is compared with the same conversation run alone on a fresh server.
    opening = "Let's start a new chat about my project. Acknowledge briefly."
    same_open = {f"c{i}": [opening, f"My project codename is {c}. Acknowledge in one short sentence.",
                           "What is my project codename? Reply with only the codename.",
                           "Repeat my project codename once more, exactly."] for i, c in enumerate(canaries)}
    alone = {}
    for n, turns in same_open.items():
        s = server("new")
        try:
            alone[n], _, _ = run_pass(s, {n: turns}, False)
        finally:
            s.stop()
            time.sleep(2)
    res["sameOpening"] = []
    for mode in ("derived", "derived", "derived", "one-shared-key"):
        s = server("new")
        try:
            box, summ, _ = timed_pass(s, same_open, True, same_key="shared-key" if mode == "one-shared-key" else None)
        finally:
            s.stop()
            time.sleep(2)
        leaks = [(i, t, txt) for i, c in enumerate(canaries) for t, txt in enumerate(box[f"c{i}"])
                 if any(o.split("-")[0] in txt.upper() for o in canaries if o != c)]
        recall = [canaries[i].lower() in box[f"c{i}"][2].lower() for i in range(3)]
        same_as_alone = {n: [a == b for a, b in zip(box[n], alone[n][n])] for n in box}
        res["sameOpening"].append({"identity": mode, "leaks": leaks, "recall": recall, "sameAsAlone": same_as_alone,
                                   "sources": [(x["req"], x["cachedTokens"], x["source"]) for x in summ["requests"]]})
        print("same-opening", mode, "leaks", len(leaks), "recall", recall, "sameAsAlone", same_as_alone, flush=True)
    res["canary"] += [{**r, "sharedPrefix": "identical-opening"} for r in res["sameOpening"]]

    json.dump(res, open(OUT, "w"), indent=1)
    regressions = [c for c in res["canary"] if c["leaks"] or not all(c["recall"])]
    print("canary regressions:", len(regressions))
    return 1 if regressions else 0


if __name__ == "__main__":
    sys.exit(main())
