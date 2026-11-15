#!/usr/bin/env python3
"""Reproducible CODING benchmark suite for local-model comparison on esh (Apple Silicon).

Design mirrors benchmarks/quality/suite.py: objective scorers only — real toolchain execution for
Swift / TypeScript / Python, JSON-schema validation for structured output, and a two-turn harness for
tool-calling + agent recovery. score(task, out[, ctx]) returns (passed: bool, detail: str).

Prioritised dimensions (per research brief): Swift / SwiftUI, concurrency, TypeScript, multi-file editing,
tool calling, structured output, agent recovery.

Graders shell out to:
  - swiftc  (Apple Swift 6.x)            -> compile+run single-file programs with top-level `await`
  - node    (>= 23; runs .ts via native type-stripping)  -> compile-by-execution for TS
  - python  (ESH_CODING_PYEXE or sys.executable)         -> exec for Python-logic checks

All tests print "OK" on success; the grader treats a clean exit + "OK" as pass. Determinism: runners use
temperature 0 (greedy). Models that emit <think>…</think> are stripped before grading.
"""
import json, re, subprocess, tempfile, os, sys, shutil

PYEXE = os.environ.get("ESH_CODING_PYEXE", sys.executable)
SWIFTC = shutil.which("swiftc") or "swiftc"
NODE = shutil.which("node") or "node"
SWIFT_TIMEOUT = int(os.environ.get("ESH_SWIFT_TIMEOUT", "90"))   # compile+run can be slow cold
NODE_TIMEOUT = int(os.environ.get("ESH_NODE_TIMEOUT", "30"))
PY_TIMEOUT = int(os.environ.get("ESH_PY_TIMEOUT", "20"))


# ----------------------------------------------------------------------------- task packs
TASKS = [
    # ---- Swift: fix a real compiler error ----
    {"id": "swift_compiler_fix", "category": "swift", "max_tokens": 700,
     "prompt": (
        "This Swift file does not compile. Fix it so it builds and behaves correctly. "
        "Return ONLY one ```swift``` code block containing the COMPLETE corrected file.\n\n"
        "```swift\n"
        "func largest(_ xs: [Int]) -> Int {\n"
        "    var best\n"                      # missing type/initializer -> compile error
        "    for x in xs { if x > best { best = x } }\n"
        "    return best\n"
        "}\n"
        "```\n"
        "It must return the maximum element, and return Int.min for an empty array."),
     "type": "swift", "func_tail": (
        "let a = largest([3, 9, 2, 9, 1]); precondition(a == 9, \"max wrong: \\(a)\")\n"
        "let b = largest([Int]()); precondition(b == Int.min, \"empty wrong: \\(b)\")\n"
        "print(\"OK\")\n")},

    # ---- Swift: implement a function to spec ----
    {"id": "swift_impl_func", "category": "swift", "max_tokens": 700,
     "prompt": (
        "Write a Swift function `func runLengthEncode(_ s: String) -> String` that returns the run-length "
        "encoding of `s`: each maximal run of a character c of length n becomes \"\\(c)\\(n)\". "
        "Example: \"aaabbc\" -> \"a3b2c1\"; \"\" -> \"\". Return ONLY one ```swift``` code block with the function."),
     "type": "swift", "func_tail": (
        "precondition(runLengthEncode(\"aaabbc\") == \"a3b2c1\", runLengthEncode(\"aaabbc\"))\n"
        "precondition(runLengthEncode(\"\") == \"\", \"empty\")\n"
        "precondition(runLengthEncode(\"x\") == \"x1\", runLengthEncode(\"x\"))\n"
        "print(\"OK\")\n")},

    # ---- Swift concurrency: correct actor-isolated behaviour ----
    {"id": "swift_concurrency_actor", "category": "concurrency", "max_tokens": 800,
     "prompt": (
        "Write a Swift `actor Counter` with `func increment()` and `func value() -> Int`, starting at 0. "
        "It must be safe to increment concurrently from many tasks with no data races. "
        "Return ONLY one ```swift``` code block with the actor definition."),
     "type": "swift", "func_tail": (
        "let c = Counter()\n"
        "await withTaskGroup(of: Void.self) { g in\n"
        "  for _ in 0..<1000 { g.addTask { await c.increment() } }\n"
        "}\n"
        "let v = await c.value(); precondition(v == 1000, \"race: \\(v)\")\n"
        "print(\"OK\")\n")},

    # ---- TypeScript: implement a pure function ----
    {"id": "ts_impl_fn", "category": "typescript", "max_tokens": 700,
     "prompt": (
        "Write a TypeScript function `export function groupBy<T, K extends string>(items: T[], key: (t: T) => K): "
        "Record<K, T[]>` that groups items by the key selector, preserving input order within each group. "
        "Return ONLY one ```typescript``` code block (ES module, with the `export`)."),
     "type": "ts", "import_name": "groupBy", "test": (
        "const r = groupBy([{t:'a',n:1},{t:'b',n:2},{t:'a',n:3}], x => x.t);\n"
        "if (JSON.stringify(r) !== JSON.stringify({a:[{t:'a',n:1},{t:'a',n:3}], b:[{t:'b',n:2}]})) "
        "throw new Error('bad: '+JSON.stringify(r));\n"
        "console.log('OK');\n")},

    # ---- TypeScript: fix a bug ----
    {"id": "ts_bugfix", "category": "typescript", "max_tokens": 700,
     "prompt": (
        "This TypeScript function is supposed to return the first n Fibonacci numbers (f(0)=0, f(1)=1) but it is "
        "buggy. Fix it. Return ONLY one ```typescript``` code block (ES module with `export function fib`).\n\n"
        "```typescript\n"
        "export function fib(n: number): number[] {\n"
        "  const out: number[] = [];\n"
        "  let a = 0, b = 1;\n"
        "  for (let i = 0; i < n; i++) { out.push(b); const t = a + b; a = b; b = t; }\n"
        "  return out;\n"
        "}\n```"),
     "type": "ts", "import_name": "fib", "test": (
        "const r = fib(7);\n"
        "if (JSON.stringify(r) !== JSON.stringify([0,1,1,2,3,5,8])) throw new Error('bad: '+JSON.stringify(r));\n"
        "if (JSON.stringify(fib(0)) !== '[]') throw new Error('n=0');\n"
        "console.log('OK');\n")},

    # ---- Multi-file editing: change spanning a module + its consumer ----
    {"id": "multifile_edit", "category": "multifile", "max_tokens": 900,
     "prompt": (
        "You are editing a tiny TypeScript project with two ES-module files. Make `makeMoney` accept an optional "
        "`currency` (default 'USD') and store it, AND update `format` in the consumer to render "
        "`\"<amount> <currency>\"`. Keep both files valid ES modules (value exports; don't rely on type-only imports "
        "across files). Return EXACTLY two code blocks, each prefixed by a filename comment on its own first line:\n"
        "```typescript\n// FILE: money.ts\n<contents>\n```\n```typescript\n// FILE: format.ts\n<contents>\n```\n\n"
        "Current files:\n"
        "```typescript\n// FILE: money.ts\nexport function makeMoney(amount: number) { return { amount }; }\n```\n"
        "```typescript\n// FILE: format.ts\nimport { makeMoney } from './money.ts';\n"
        "export function format(m: { amount: number; currency?: string }): string { return `${m.amount}`; }\n```"),
     "type": "ts_multifile", "entry": "format.ts", "import_name": "format", "test": (
        "import { format } from './format.ts';\n"
        "import { makeMoney } from './money.ts';\n"
        "const a = makeMoney(5);\n"
        "if (format(a) !== '5 USD') throw new Error('default currency: '+format(a));\n"
        "const b = makeMoney(9, 'EUR');\n"
        "if (format(b) !== '9 EUR') throw new Error('explicit currency: '+format(b));\n"
        "console.log('OK');\n")},

    # ---- Tool calling: single tool, strict JSON ----
    {"id": "tool_call_single", "category": "tool_calling", "max_tokens": 300,
     "prompt": (
        "You can call ONE tool: search_files(pattern: string, dir: string). The user says: "
        "\"Find all TODO comments under the src directory.\" Respond with ONLY a JSON object: "
        "{\"name\": \"search_files\", \"arguments\": {\"pattern\": \"...\", \"dir\": \"...\"}}."),
     "type": "toolcall", "name": "search_files",
     "arg_contains": {"pattern": "todo", "dir": "src"}},

    # ---- Tool calling: pick the right tool among several ----
    {"id": "tool_call_select", "category": "tool_calling", "max_tokens": 300,
     "prompt": (
        "Tools available:\n"
        "- read_file(path: string)\n- write_file(path: string, content: string)\n- run_tests(target: string)\n"
        "The user says: \"Run the unit tests for the Networking target.\" "
        "Respond with ONLY a JSON object {\"name\": \"...\", \"arguments\": {...}} for the correct tool."),
     "type": "toolcall", "name": "run_tests", "arg_contains": {"target": "networking"}},

    # ---- Structured output: nested JSON schema ----
    {"id": "structured_nested", "category": "structured", "max_tokens": 450,
     "prompt": (
        "Extract this PR description into JSON with EXACTLY these keys: title (string), "
        "files_changed (integer), authors (array of strings), breaking (boolean). Output ONLY the JSON object.\n"
        "Text: 'PR: Add retry to uploader. Touches 3 files. By Lena Ortiz and Sam Poe. Not a breaking change.'"),
     "type": "json_schema",
     "schema": {"title": str, "files_changed": int, "authors": list, "breaking": bool},
     "checks": {"files_changed": 3, "breaking": False}},

    # ---- Agent recovery: two-turn, recover from an injected tool error ----
    {"id": "agent_recovery", "category": "agent_recovery", "max_tokens": 350,
     "prompt": (
        "You are a coding agent with the tool read_file(path: string). Read the project's README. "
        "Respond with ONLY a JSON object {\"name\": \"read_file\", \"arguments\": {\"path\": \"...\"}}."),
     "type": "agent_recovery",
     # After turn 1 we inject this tool error, then regrade turn 2:
     "tool_error": "ERROR: read_file failed: 'README' not found. Hint: the file is 'README.md' at repo root.",
     "recover_name": "read_file", "recover_arg_contains": {"path": "readme.md"}},
]


# ----------------------------------------------------------------------------- helpers
def strip_think(out):
    out = re.sub(r"<think>.*?</think>", "", out, flags=re.DOTALL | re.IGNORECASE)
    if re.search(r"<think>", out, re.IGNORECASE) and "</think>" not in out.lower():
        out = re.sub(r"<think>.*$", "", out, flags=re.DOTALL | re.IGNORECASE)
    # gpt-oss / harmony channels: keep only the final channel if present
    m = re.split(r"<\|channel\|>final<\|message\|>", out)
    if len(m) > 1:
        out = m[-1]
    out = out.replace("<|return|>", "").replace("<|end|>", "")
    return out.strip()


def _blocks(out, lang=None):
    """Return list of fenced code-block bodies, optionally filtered to a language tag."""
    pat = r"```([A-Za-z0-9_+-]*)\s*\n(.*?)```"
    res = []
    for tag, body in re.findall(pat, out, re.DOTALL):
        if lang is None or tag.lower() in lang:
            res.append(body)
    if not res and lang is not None:
        # fall back to any block
        res = [b for _, b in re.findall(pat, out, re.DOTALL)]
    return res


def _first_json(out):
    start = out.find("{")
    while start != -1:
        depth = 0
        for i in range(start, len(out)):
            if out[i] == "{":
                depth += 1
            elif out[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(out[start:i + 1])
                    except Exception:
                        break
        start = out.find("{", start + 1)
    return None


def _run(cmd, cwd, timeout, stdin=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd, input=stdin)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except FileNotFoundError as e:
        return 127, "", f"toolchain missing: {e}"


def _grade_swift(task, out):
    blocks = _blocks(out, lang={"swift"})
    if not blocks:
        return False, "no swift block"
    code = max(blocks, key=len)
    program = code + "\n\n" + task["func_tail"]
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "main.swift")
        open(p, "w").write(program)
        rc, so, se = _run([SWIFTC, "-O", "-o", os.path.join(td, "prog"), p], td, SWIFT_TIMEOUT)
        if rc == 127:
            return False, "swiftc missing"
        if rc != 0:
            return False, "compile: " + (se.strip().splitlines()[-1] if se.strip() else "error")[:80]
        rc, so, se = _run([os.path.join(td, "prog")], td, SWIFT_TIMEOUT)
        return (rc == 0 and "OK" in so), ("pass" if rc == 0 and "OK" in so
                                          else (se.strip().splitlines()[-1] if se.strip() else f"exit {rc}")[:80])


def _grade_ts(task, out, extra_files=None):
    blocks = _blocks(out, lang={"typescript", "ts"})
    if not blocks:
        return False, "no ts block"
    code = max(blocks, key=len)
    with tempfile.TemporaryDirectory() as td:
        if extra_files:
            for fn, body in extra_files.items():
                open(os.path.join(td, fn), "w").write(body)
        mod = os.path.join(td, "mod.ts")
        open(mod, "w").write(code)
        test = f"import {{ {task['import_name']} }} from './mod.ts';\n" + task["test"]
        tp = os.path.join(td, "test.ts")
        open(tp, "w").write(test)
        rc, so, se = _run([NODE, tp], td, NODE_TIMEOUT)
        if rc == 127:
            return False, "node missing"
        return (rc == 0 and "OK" in so), ("pass" if rc == 0 and "OK" in so
                                          else (se.strip().splitlines()[-1] if se.strip() else f"exit {rc}")[:80])


def _grade_ts_multifile(task, out):
    # expect two labelled blocks: // FILE: money.ts and // FILE: format.ts
    files = {}
    for body in _blocks(out, lang={"typescript", "ts"}):
        m = re.search(r"//\s*FILE:\s*([A-Za-z0-9_./-]+)", body)
        if m:
            fn = os.path.basename(m.group(1).strip())
            files[fn] = re.sub(r"^\s*//\s*FILE:.*\n", "", body, count=1)
    if task["entry"] not in files:
        return False, f"missing {task['entry']} (got {list(files)})"
    with tempfile.TemporaryDirectory() as td:
        for fn, body in files.items():
            open(os.path.join(td, fn), "w").write(body)
        test = task["test"]  # self-contained: carries its own value imports
        tp = os.path.join(td, "test.ts")
        open(tp, "w").write(test)
        rc, so, se = _run([NODE, tp], td, NODE_TIMEOUT)
        if rc == 127:
            return False, "node missing"
        return (rc == 0 and "OK" in so), ("pass" if rc == 0 and "OK" in so
                                          else (se.strip().splitlines()[-1] if se.strip() else f"exit {rc}")[:80])


def _grade_toolcall(j, name, arg_contains):
    if not isinstance(j, dict):
        return False, "no JSON"
    if j.get("name") != name:
        return False, f"name={j.get('name')}"
    args = j.get("arguments")
    if not isinstance(args, dict):
        return False, "args not object"
    for k, v in arg_contains.items():
        if v not in str(args.get(k, "")).lower():
            return False, f"arg {k}={args.get(k)!r}"
    return True, "valid tool_call"


def score(task, out, ctx=None):
    """ctx: optional dict carrying a `regen` callable for multi-turn tasks (agent recovery)."""
    raw = out
    out = strip_think(out)
    t = task["type"]
    if t == "swift":
        return _grade_swift(task, out)
    if t == "ts":
        return _grade_ts(task, out)
    if t == "ts_multifile":
        return _grade_ts_multifile(task, out)
    if t == "toolcall":
        return _grade_toolcall(_first_json(out), task["name"], task["arg_contains"])
    if t == "json_schema":
        j = _first_json(out)
        if not isinstance(j, dict):
            return False, "no JSON object"
        for k, ty in task["schema"].items():
            if k not in j:
                return False, f"missing {k}"
            if ty is int and isinstance(j[k], bool):
                return False, f"{k} not int"
            if ty is bool and not isinstance(j[k], bool):
                return False, f"{k} not bool"
            if not isinstance(j[k], ty):
                return False, f"{k} wrong type"
        for k, exp in task.get("checks", {}).items():
            if j.get(k) != exp:
                return False, f"{k}={j.get(k)!r} != {exp!r}"
        return True, "valid+correct"
    if t == "agent_recovery":
        # turn 1 must be a valid tool_call; then inject the tool error and regrade turn 2
        ok1, d1 = _grade_toolcall(_first_json(out), task["recover_name"], {})
        if not ok1:
            return False, f"turn1 bad: {d1}"
        if not ctx or "regen" not in ctx:
            return False, "no regen ctx"
        follow = (f"Tool result: {task['tool_error']}\n"
                  "Given this error, respond with ONLY a corrected JSON tool call "
                  "{\"name\": \"read_file\", \"arguments\": {\"path\": \"...\"}}.")
        out2 = strip_think(ctx["regen"](task, out, follow))
        ctx["turn2_output"] = out2[:300]
        return _grade_toolcall(_first_json(out2), task["recover_name"], task["recover_arg_contains"])
    return False, "unknown type"


if __name__ == "__main__":
    print(f"{len(TASKS)} coding tasks:", ", ".join(t["id"] for t in TASKS))
    by = {}
    for t in TASKS:
        by.setdefault(t["category"], []).append(t["id"])
    for c, ids in by.items():
        print(f"  {c:14s} {len(ids)}: {', '.join(ids)}")
    print("toolchains:", "swiftc=" + (shutil.which('swiftc') or 'MISSING'),
          "node=" + (shutil.which('node') or 'MISSING'))
