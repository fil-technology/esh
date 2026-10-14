#!/usr/bin/env python3
"""Validate the coding suite's graders against the REAL toolchains (swiftc, node) with golden
correct/incorrect solutions — no model, no memory gate. Proves each grader compiles+runs code and
discriminates pass from fail. Writes a JSON report. Exit 0 iff every grader discriminates correctly.

Usage: validate_graders.py [out_json]
"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import suite_coding as S

SW = "```swift\n%s\n```"
TS = "```typescript\n%s\n```"

GOLDEN = {
 "swift_compiler_fix": (
   SW % "func largest(_ xs: [Int]) -> Int {\n  var best = Int.min\n  for x in xs { if x > best { best = x } }\n  return best\n}",
   SW % "func largest(_ xs: [Int]) -> Int {\n  var best = 0\n  for x in xs { if x > best { best = x } }\n  return best\n}"),  # 0 for empty != Int.min
 "swift_impl_func": (
   SW % "func runLengthEncode(_ s: String) -> String {\n  var out = \"\"; var prev: Character? = nil; var c = 0\n  for ch in s { if ch == prev { c += 1 } else { if let p = prev { out += \"\\(p)\\(c)\" }; prev = ch; c = 1 } }\n  if let p = prev { out += \"\\(p)\\(c)\" }\n  return out\n}",
   SW % "func runLengthEncode(_ s: String) -> String { return s }"),
 "swift_concurrency_actor": (
   SW % "actor Counter {\n  private var n = 0\n  func increment() { n += 1 }\n  func value() -> Int { n }\n}",
   SW % "actor Counter {\n  private var n = 0\n  func increment() { n += 2 }\n  func value() -> Int { n }\n}"),  # 2000 != 1000
 "ts_impl_fn": (
   TS % "export function groupBy<T, K extends string>(items: T[], key: (t: T) => K): Record<K, T[]> {\n  const out = {} as Record<K, T[]>;\n  for (const it of items) { const k = key(it); (out[k] ||= []).push(it); }\n  return out;\n}",
   TS % "export function groupBy<T, K extends string>(items: T[], key: (t: T) => K): Record<K, T[]> {\n  return {} as Record<K, T[]>;\n}"),
 "ts_bugfix": (
   TS % "export function fib(n: number): number[] {\n  const out: number[] = []; let a = 0, b = 1;\n  for (let i = 0; i < n; i++) { out.push(a); const t = a + b; a = b; b = t; }\n  return out;\n}",
   TS % "export function fib(n: number): number[] {\n  const out: number[] = []; let a = 0, b = 1;\n  for (let i = 0; i < n; i++) { out.push(b); const t = a + b; a = b; b = t; }\n  return out;\n}"),  # pushes b -> wrong
 "multifile_edit": (
   (TS % "// FILE: money.ts\nexport function makeMoney(amount: number, currency: string = 'USD') { return { amount, currency }; }") + "\n" +
   (TS % "// FILE: format.ts\nimport { makeMoney } from './money.ts';\nexport function format(m: { amount: number; currency?: string }): string { return `${m.amount} ${m.currency ?? 'USD'}`; }"),
   (TS % "// FILE: format.ts\nimport { makeMoney } from './money.ts';\nexport function format(m: { amount: number; currency?: string }): string { return `${m.amount}`; }")),  # missing money.ts edit + no currency
 "tool_call_single": (
   '{"name": "search_files", "arguments": {"pattern": "TODO", "dir": "src"}}',
   '{"name": "search_files", "arguments": {"pattern": "TODO"}}'),  # missing dir
 "tool_call_select": (
   '{"name": "run_tests", "arguments": {"target": "Networking"}}',
   '{"name": "read_file", "arguments": {"path": "Networking"}}'),  # wrong tool
 "structured_nested": (
   '{"title": "Add retry to uploader", "files_changed": 3, "authors": ["Lena Ortiz", "Sam Poe"], "breaking": false}',
   '{"title": "Add retry to uploader", "files_changed": 3, "authors": ["Lena Ortiz", "Sam Poe"], "breaking": true}'),  # breaking wrong
 "agent_recovery": (
   '{"name": "read_file", "arguments": {"path": "README"}}',    # valid turn1; regen decides turn2
   '{"name": "read_file", "arguments": {"path": "README"}}'),
}

# For agent_recovery, turn-2 behaviour is controlled by a scripted regen, not the turn-1 text.
REGEN = {
 "correct": lambda task, out, follow: '{"name": "read_file", "arguments": {"path": "README.md"}}',
 "wrong":   lambda task, out, follow: '{"name": "read_file", "arguments": {"path": "README"}}',  # did not recover
}


def main():
    out_json = sys.argv[1] if len(sys.argv) > 1 else "grader-validation.json"
    taskmap = {t["id"]: t for t in S.TASKS}
    rows = []
    all_ok = True
    for tid, (good, bad) in GOLDEN.items():
        task = taskmap[tid]
        if task["type"] == "agent_recovery":
            pg, dg = S.score(task, good, {"regen": REGEN["correct"]})
            pb, db = S.score(task, bad, {"regen": REGEN["wrong"]})
        else:
            pg, dg = S.score(task, good)
            pb, db = S.score(task, bad)
        discriminates = (pg is True and pb is False)
        all_ok = all_ok and discriminates
        rows.append({"id": tid, "category": task["category"], "golden_correct_pass": pg, "detail_correct": dg,
                     "golden_wrong_pass": pb, "detail_wrong": db, "discriminates": discriminates})
        flag = "OK " if discriminates else "XX "
        print(f"[{flag}] {tid:24s} correct={str(pg):5s}({dg[:28]})  wrong={str(pb):5s}({db[:28]})", flush=True)
    report = {"label": "GRADER VALIDATION (golden in/out, real toolchains)",
              "toolchains": {"swiftc": S.SWIFTC, "node": S.NODE},
              "all_graders_discriminate": all_ok,
              "passed": sum(r["discriminates"] for r in rows), "total": len(rows), "results": rows}
    json.dump(report, open(out_json, "w"), indent=2)
    print(f"\n{report['passed']}/{report['total']} graders discriminate correctly -> {'ALL GOOD' if all_ok else 'FAILURES'}")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
