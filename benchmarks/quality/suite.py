#!/usr/bin/env python3
"""Reproducible quality suite for local-model comparison (brief §15). Objective scorers only — executable tests
for code, schema validation for JSON, exact-match for reasoning, regex for instruction-following, a tool-call
check, and a needle retrieval. Shared by the MLX and llama-server runners; each runner only supplies text
generation (temperature 0 for determinism). score() returns (passed: bool, detail: str)."""
import json, re, subprocess, tempfile, os, sys

PYEXE = os.environ.get("ESH_QUALITY_PYEXE", sys.executable)

# ---- a long-ish context for the needle task (~1.5k tokens of filler + one planted fact) ----
_FILLER = ("The quarterly logistics review covered warehouse throughput, carrier SLAs, and seasonal demand. "
           "Teams discussed pallet utilization, dock scheduling, and returns processing at length. ") * 40
NEEDLE_CTX = (_FILLER + "\nIMPORTANT OPERATIONAL FACT: The emergency access code for the Rotterdam cold-storage "
              "facility is PELICAN-7731.\n" + _FILLER)

TASKS = [
    # ---- coding (executable) ----
    {"id": "code_two_sum", "category": "coding", "max_tokens": 500,
     "prompt": "Write a Python function `two_sum(nums, target)` that returns a list of the two indices whose "
               "values add up to target (any order). Assume exactly one solution. Return ONLY one ```python``` code block.",
     "type": "code", "func": "two_sum",
     "tests": "assert sorted(two_sum([2,7,11,15],9))==[0,1]; assert sorted(two_sum([3,2,4],6))==[1,2]; "
              "assert sorted(two_sum([3,3],6))==[0,1]"},
    {"id": "code_roman", "category": "coding", "max_tokens": 600,
     "prompt": "Write a Python function `roman_to_int(s)` converting a Roman numeral string to an integer "
               "(handles subtractive forms like IV, IX, XL, XC, CD, CM). Return ONLY one ```python``` code block.",
     "type": "code", "func": "roman_to_int",
     "tests": "assert roman_to_int('III')==3; assert roman_to_int('IV')==4; assert roman_to_int('IX')==9; "
              "assert roman_to_int('LVIII')==58; assert roman_to_int('MCMXCIV')==1994"},
    {"id": "code_debounce_min", "category": "coding", "max_tokens": 700,
     "prompt": "Write a Python class `Debouncer` with `__init__(self, delay)` and a method `call(self, fn)` such "
               "that if call() is invoked again within `delay` seconds, the previous pending fn is cancelled and "
               "only the latest runs after the delay. Use threading.Timer. Return ONLY one ```python``` code block.",
     "type": "code", "func": "Debouncer",
     "tests": "import time\nlog=[]\nd=Debouncer(0.2)\n"
              "d.call(lambda: log.append('a')); d.call(lambda: log.append('b')); d.call(lambda: log.append('c'))\n"
              "time.sleep(0.5)\nassert log==['c'], log"},
    # ---- reasoning (exact) ----
    {"id": "reason_math", "category": "reasoning", "max_tokens": 500,
     "prompt": "A tank holds 240 liters. Pipe A fills it at 12 L/min, pipe B drains it at 4 L/min. Both open "
               "from empty. After how many minutes is the tank full? Reason briefly, then end with 'ANSWER: <number>'.",
     "type": "exact", "answers": ["30"]},
    {"id": "reason_logic", "category": "reasoning", "max_tokens": 500,
     "prompt": "Five houses in a row, numbered 1-5 left to right. The red house is immediately right of the blue "
               "house. The blue house is house 2. What number is the red house? End with 'ANSWER: <number>'.",
     "type": "exact", "answers": ["3"]},
    # ---- structured output (schema) ----
    {"id": "structured_json", "category": "structured", "max_tokens": 400,
     "prompt": "Extract this into JSON with keys name (string), age (integer), skills (array of strings). "
               "Text: 'Dana Ruiz, 34, works in Swift, Python and Rust.' Output ONLY the JSON object.",
     "type": "json", "required": {"name": str, "age": int, "skills": list}},
    # ---- instruction following (regex) ----
    {"id": "instruction_3bullets", "category": "instruction", "max_tokens": 300,
     "prompt": "List three benefits of unit testing. Reply with EXACTLY three lines, each starting with '- ' "
               "(dash space), and NO other text, preamble, or blank lines.",
     "type": "regex_lines", "n_lines": 3, "prefix": "- "},
    # ---- tool calling (json emit) ----
    {"id": "tool_call", "category": "tool_calling", "max_tokens": 300,
     "prompt": "You have one tool: get_weather(city: string). The user asks: \"What's the weather in Paris?\" "
               "Respond with ONLY a JSON object of the form {\"name\": \"get_weather\", \"arguments\": {\"city\": \"...\"}}.",
     "type": "toolcall", "name": "get_weather", "arg_key": "city", "arg_val": "paris"},
    # ---- long context retrieval (needle) ----
    {"id": "needle", "category": "long_context", "max_tokens": 200,
     "prompt": "Read the following document and answer the question.\n\n" + NEEDLE_CTX +
               "\n\nQuestion: What is the emergency access code for the Rotterdam cold-storage facility? "
               "End with 'ANSWER: <code>'.",
     "type": "exact", "answers": ["pelican-7731"]},
]


def _extract_code(out):
    m = re.search(r"```(?:python)?\s*\n(.*?)```", out, re.DOTALL)
    return m.group(1) if m else out


def _first_json(out):
    # find the first balanced {...}
    start = out.find("{")
    while start != -1:
        depth = 0
        for i in range(start, len(out)):
            if out[i] == "{": depth += 1
            elif out[i] == "}":
                depth -= 1
                if depth == 0:
                    try: return json.loads(out[start:i+1])
                    except Exception: break
        start = out.find("{", start + 1)
    return None


def strip_think(out):
    """Remove <think>...</think> reasoning so scoring sees the final answer only. Handles an unclosed <think>
    (budget truncation) by dropping everything from the last <think> if no closing tag follows."""
    out = re.sub(r"<think>.*?</think>", "", out, flags=re.DOTALL | re.IGNORECASE)
    if re.search(r"<think>", out, re.IGNORECASE) and "</think>" not in out.lower():
        out = re.sub(r"<think>.*$", "", out, flags=re.DOTALL | re.IGNORECASE)
    return out.strip()


def score(task, out):
    out = strip_think(out)
    t = task["type"]
    if t == "code":
        code = _extract_code(out)
        script = code + "\n\n" + task["tests"] + "\nprint('OK')\n"
        with tempfile.TemporaryDirectory() as td:
            p = os.path.join(td, "t.py")
            open(p, "w").write(script)
            try:
                r = subprocess.run([PYEXE, p], capture_output=True, text=True, timeout=20, cwd=td)
            except subprocess.TimeoutExpired:
                return False, "exec timeout"
            return (r.returncode == 0 and "OK" in r.stdout), (r.stderr.strip().splitlines()[-1] if r.returncode else "pass")
    if t == "exact":
        low = out.lower()
        m = re.findall(r"answer:\s*([^\s].*?)\s*$", low, re.MULTILINE)
        cand = (m[-1] if m else low).strip().strip(".")
        ok = any(a.lower() in cand or a.lower() in low for a in task["answers"])
        return ok, f"got '{cand[:40]}'"
    if t == "json":
        j = _first_json(out)
        if not isinstance(j, dict): return False, "no JSON object"
        for k, ty in task["required"].items():
            if k not in j: return False, f"missing {k}"
            if ty is int and isinstance(j[k], bool): return False, f"{k} not int"
            if not isinstance(j[k], ty): return False, f"{k} wrong type"
        return True, "valid"
    if t == "regex_lines":
        lines = [l for l in out.strip().splitlines() if l.strip() != ""]
        ok = len(lines) == task["n_lines"] and all(l.startswith(task["prefix"]) for l in lines)
        return ok, f"{len(lines)} lines"
    if t == "toolcall":
        j = _first_json(out)
        if not isinstance(j, dict): return False, "no JSON"
        ok = (j.get("name") == task["name"] and isinstance(j.get("arguments"), dict)
              and task["arg_val"] in str(j["arguments"].get(task["arg_key"], "")).lower())
        return ok, f"got {json.dumps(j)[:60]}"
    return False, "unknown type"


if __name__ == "__main__":
    print(f"{len(TASKS)} tasks:", ", ".join(t["id"] for t in TASKS))
