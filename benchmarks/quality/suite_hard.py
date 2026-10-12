#!/usr/bin/env python3
"""Harder, DISCRIMINATING quality suite (brief P1) — designed to separate the 30B and 80B where the easy 9-task
smoke suite could not. Objective scorers only (executable Python unit tests, exact-match multi-step reasoning,
all-needles long-context retrieval, ordered multi-step tool-call plans, nested-JSON schema). Reuses suite.py's
scorers (code/exact/json/regex/toolcall/strip_think) + adds `multineedle` and `plan`. Harness-shared with the
MLX + llama-server runners via ESH_SUITE=suite_hard. v1 = 16 hard tasks (expandable toward 50; Swift-compile
and SwiftUI tasks need a swiftc/app-build scorer — a documented follow-up)."""
import re, json
import suite  # reuse scorers + helpers
from suite import _extract_code, _first_json, strip_think  # noqa

_LONGDOC = ("Release engineering notes. " + ("Builds are reproducible via pinned toolchains and lockfiles; "
            "artifacts are content-addressed and cached across CI runners. ") * 60 +
            "\nFACT A: the staging deploy key rotates every 14 days.\n" +
            ("Observability covers traces, metrics, and structured logs with per-tenant sampling. ") * 60 +
            "\nFACT B: the canary cohort is 3 percent of traffic.\n" +
            ("Incident response uses sev levels 1 through 4 with automatic paging for sev1 and sev2. ") * 60 +
            "\nFACT C: the rollback budget is 7 minutes.\n" +
            ("Capacity planning assumes 35 percent annual growth and quarterly load tests. ") * 40)

TASKS = [
    # ---------- harder executable Python ----------
    {"id": "h_lru", "category": "coding", "max_tokens": 900, "type": "code", "func": "LRUCache",
     "prompt": "Implement a Python class `LRUCache` with `__init__(self, capacity)`, `get(self, key)->int` "
               "(returns -1 if absent) and `put(self, key, value)`. Evict the least-recently-used entry when over "
               "capacity. get and put must both count as 'use'. Return ONLY one ```python``` block.",
     "tests": "c=LRUCache(2); c.put(1,1); c.put(2,2); assert c.get(1)==1; c.put(3,3); assert c.get(2)==-1; "
              "c.put(4,4); assert c.get(1)==-1; assert c.get(3)==3; assert c.get(4)==4"},
    {"id": "h_toposort", "category": "coding", "max_tokens": 900, "type": "code", "func": "topo_order",
     "prompt": "Write `topo_order(n, edges)` returning a valid topological ordering (list) of nodes 0..n-1 given "
               "directed `edges` as (u,v) meaning u before v; return [] if a cycle exists. Return ONLY one ```python``` block.",
     "tests": "r=topo_order(4,[(0,1),(1,2),(0,2),(2,3)]); assert r.index(0)<r.index(1)<r.index(2)<r.index(3); "
              "assert topo_order(2,[(0,1),(1,0)])==[]"},
    {"id": "h_intervals", "category": "coding", "max_tokens": 800, "type": "code", "func": "merge_intervals",
     "prompt": "Write `merge_intervals(intervals)` merging overlapping [start,end] intervals, returning a sorted "
               "list of disjoint intervals. Return ONLY one ```python``` block.",
     "tests": "assert merge_intervals([[1,3],[2,6],[8,10],[15,18]])==[[1,6],[8,10],[15,18]]; "
              "assert merge_intervals([[1,4],[4,5]])==[[1,5]]; assert merge_intervals([])==[]"},
    {"id": "h_tokenizer", "category": "coding", "max_tokens": 900, "type": "code", "func": "tokenize",
     "prompt": "Write `tokenize(expr)` that tokenizes a math expression string into a list of tokens: integers "
               "(as str of digits), the operators + - * / ( ). Ignore spaces. e.g. tokenize('12 + (3*4)') -> "
               "['12','+','(','3','*','4',')']. Return ONLY one ```python``` block.",
     "tests": "assert tokenize('12 + (3*4)')==['12','+','(','3','*','4',')']; assert tokenize('1-2')==['1','-','2']"},
    {"id": "h_ratelimit", "category": "coding", "max_tokens": 1000, "type": "code", "func": "RateLimiter",
     "prompt": "Implement `RateLimiter` with `__init__(self, max_calls, period)` and `allow(self, now)->bool` "
               "implementing a sliding-window limiter: allow at most max_calls within any window of `period` "
               "seconds, using the `now` timestamp passed in. Return ONLY one ```python``` block.",
     "tests": "r=RateLimiter(2,10); assert r.allow(0)==True; assert r.allow(1)==True; assert r.allow(2)==False; "
              "assert r.allow(100)==True"},
    {"id": "h_jsondiff", "category": "coding", "max_tokens": 1000, "type": "code", "func": "json_diff",
     "prompt": "Write `json_diff(a, b)` returning a dict of top-level keys whose values differ between dicts a and "
               "b, mapping key -> [a_value, b_value]. Keys only in one side use the sentinel None for the missing "
               "side. Return ONLY one ```python``` block.",
     "tests": "assert json_diff({'x':1,'y':2},{'x':1,'y':3})=={'y':[2,3]}; "
              "assert json_diff({'a':1},{'b':2})=={'a':[1,None],'b':[None,2]}"},
    # ---------- complex multi-step reasoning (exact) ----------
    {"id": "r_trains", "category": "reasoning", "max_tokens": 700, "type": "exact", "answers": ["270"],
     "prompt": "Two trains start 300 km apart moving toward each other, one at 40 km/h, the other at 60 km/h. "
               "A bird flies at 90 km/h from the faster train toward the other and back repeatedly until they meet. "
               "Total distance the bird flies, in km? Reason step by step, then end 'ANSWER: <number>'."},
    {"id": "r_ages", "category": "reasoning", "max_tokens": 700, "type": "exact", "answers": ["36"],
     "prompt": "A father is currently three times as old as his son. In 12 years he will be twice as old as his son. "
               "How old is the father now? End with 'ANSWER: <number>'."},
    {"id": "r_grid", "category": "reasoning", "max_tokens": 900, "type": "exact", "answers": ["blue"],
     "prompt": "Three houses in a row (1,2,3), each a different color: red, green, or blue. The green house is not "
               "first. The red house is immediately to the left of the green house. House 1 is not red. What color "
               "is house 1? Reason step by step, then end with 'ANSWER: <color>'."},
    {"id": "r_units", "category": "reasoning", "max_tokens": 700, "type": "exact", "answers": ["30"],
     "prompt": "A tap fills a 1800-liter tank. It runs at 500 mL/second. How many minutes to fill half the tank? "
               "End with 'ANSWER: <number>'."},
    {"id": "r_prob", "category": "reasoning", "max_tokens": 800, "type": "exact", "answers": ["2/5", "0.4", "40%"],
     "prompt": "A bag has 3 red and 3 blue balls. You draw two without replacement. What is the probability both "
               "are the same color? Give the simplest fraction. End with 'ANSWER: <fraction>'."},
    # ---------- long-context, ALL needles ----------
    {"id": "lc_allfacts", "category": "long_context", "max_tokens": 300, "type": "multineedle",
     "needles": ["14", "3 percent", "7 minutes"],
     "prompt": "Read the document and answer.\n\n" + _LONGDOC + "\n\nList, as three lines 'A: ...', 'B: ...', "
               "'C: ...', the staging deploy key rotation period, the canary cohort size, and the rollback budget."},
    {"id": "lc_synth", "category": "long_context", "max_tokens": 300, "type": "exact", "answers": ["21", "21 days"],
     "prompt": "Read the document.\n\n" + _LONGDOC + "\n\nIf the deploy key rotates every 14 days and the rollback "
               "budget is 7 minutes, what is the sum of the key-rotation period (in days) and the rollback budget "
               "(in minutes), as a single number? End with 'ANSWER: <number>'."},
    # ---------- multi-step tool / agent plan ----------
    {"id": "t_plan", "category": "tool_calling", "max_tokens": 500, "type": "plan",
     "sequence": ["search_flights", "book_flight", "send_email"],
     "prompt": "Tools: search_flights(origin,dest,date), book_flight(flight_id), send_email(to,body). Goal: find a "
               "flight NYC->LON on 2026-12-01, book the first result, then email alice@x.com a confirmation. "
               "Output ONLY a JSON array of steps, each {\"tool\": <name>, \"args\": {...}}, in the correct order."},
    {"id": "t_plan2", "category": "tool_calling", "max_tokens": 500, "type": "plan",
     "sequence": ["read_file", "run_tests"],
     "prompt": "Tools: read_file(path), write_file(path,content), run_tests(). Goal: open src/app.py to inspect it, "
               "then run the test suite. Do NOT write anything. Output ONLY a JSON array of steps, each "
               "{\"tool\": <name>, \"args\": {...}}, in order."},
    # ---------- nested structured output ----------
    {"id": "s_nested", "category": "structured", "max_tokens": 500, "type": "json_nested",
     "prompt": "Output ONLY JSON: an object with key 'user' (object: name string, roles array of strings) and key "
               "'active' (boolean). Data: Mia Chen is an admin and editor, account active. "},
]


def score(task, out):
    t = task["type"]
    if t == "multineedle":
        clean = strip_think(out).lower()
        missing = [n for n in task["needles"] if n.lower() not in clean]
        return (len(missing) == 0), ("all needles" if not missing else f"missing {missing}")
    if t == "plan":
        clean = strip_think(out)
        arr = None
        m = re.search(r"\[.*\]", clean, re.DOTALL)
        if m:
            try: arr = json.loads(m.group(0))
            except Exception: arr = None
        if not isinstance(arr, list) or not arr:
            return False, "no JSON array"
        tools = [str(s.get("tool", "")) for s in arr if isinstance(s, dict)]
        return (tools == task["sequence"]), f"got {tools}"
    if t == "json_nested":
        j = _first_json(strip_think(out))
        if not isinstance(j, dict): return False, "no JSON"
        u = j.get("user")
        ok = (isinstance(u, dict) and isinstance(u.get("name"), str) and isinstance(u.get("roles"), list)
              and all(isinstance(r, str) for r in u.get("roles", [])) and isinstance(j.get("active"), bool))
        return ok, ("valid" if ok else f"shape {json.dumps(j)[:80]}")
    return suite.score(task, out)   # delegate code/exact/json/regex/toolcall


if __name__ == "__main__":
    print(f"{len(TASKS)} hard tasks:", ", ".join(t["id"] for t in TASKS))
