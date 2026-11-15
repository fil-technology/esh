#!/usr/bin/env python3
"""Run the esh CODING benchmark suite against an MLX model through a memory-safe gate.

This is the reproducible runner for benchmarks/coding/suite_coding.py. It drives the SAME engine esh's
text backend uses (the mlx_lm worker) and applies esh's memory-safety rule BEFORE loading weights, so a
run on this machine respects the same guard as `esh`'s live path (EshCore/Runtime/MemorySafetyPreflight.swift).

Usage:  run_coding_mlx.py <hf_repo_or_local_path> <out_json> [required_peak_gb]
Env:    ESH_CODING_PYEXE  python used to exec Python graders (default: this interpreter)
        ESH_FORCE=1        override the memory gate (NOT recommended; off by default)
        ESH_MAX_TOKENS     cap per-task max_tokens (default: use task value)

Determinism: temperature 0 (greedy). Qwen3 hybrid thinking disabled when supported (fair like-for-like).
"""
import sys, os, json, time, re, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import suite_coding as suite


# --------------------------------------------------------------- host resources + esh memory gate
def _vm_available_gb():
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
        pg = 16384
        def g(pat):
            m = re.search(pat, out)
            return int(m.group(1)) * pg if m else 0
        # available ~= free + inactive + speculative + purgeable (reclaimable without swap)
        b = g(r"Pages free:\s+(\d+)") + g(r"Pages inactive:\s+(\d+)") + g(r"Pages speculative:\s+(\d+)") + g(r"Pages purgeable:\s+(\d+)")
        return b / 1e9
    except Exception:
        return None


def _total_ram_gb():
    try:
        return int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip()) / 1e9
    except Exception:
        return 0.0


def _system_volume_free_gb():
    try:
        out = subprocess.run(["df", "-k", "/System/Volumes/Data"], capture_output=True, text=True).stdout.splitlines()[-1]
        avail_kb = int(out.split()[3])
        return avail_kb * 1024 / 1e9
    except Exception:
        return None


def _swapusage():
    try:
        out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout.strip()
        return out  # e.g. "total = 3072.00M  used = 1234.50M  free = 1837.50M (encrypted)"
    except Exception:
        return None


def memory_gate(required_peak_gb):
    """Replicates esh EshCore/Runtime/MemorySafetyPreflight.swift:
       smallModelFloorGB=4.0, swapDiskFloorGB=3.0. Gates when required>98% RAM, or deficit>40% RAM,
       or the internal (swap) volume cannot absorb the deficit plus the 3 GB swap floor."""
    total = _total_ram_gb()
    avail = _vm_available_gb()
    sysfree = _system_volume_free_gb()
    SMALL_FLOOR, SWAP_FLOOR = 4.0, 3.0
    info = {"total_ram_gb": round(total, 1), "available_ram_gb": round(avail, 1) if avail else None,
            "system_volume_free_gb": round(sysfree, 2) if sysfree else None,
            "required_peak_gb": round(required_peak_gb, 2), "swap_before": _swapusage()}
    reasons = []
    if required_peak_gb <= SMALL_FLOOR:
        info.update(decision="ALLOW", reason=f"small model (<= {SMALL_FLOOR} GB floor)")
        return True, info
    if total and required_peak_gb > total * 0.98:
        reasons.append(f"required {required_peak_gb:.1f} > 98% RAM ({total:.1f})")
    deficit = (required_peak_gb - avail) if avail is not None else required_peak_gb
    if total and deficit > total * 0.40:
        reasons.append(f"deficit {deficit:.1f} > 40% RAM")
    if sysfree is not None and sysfree < max(0.0, deficit) + SWAP_FLOOR:
        reasons.append(f"system-volume free {sysfree:.2f} GB < deficit {max(0.0,deficit):.1f} + swap floor {SWAP_FLOOR} "
                       f"(cannot grow swap safely)")
    if reasons:
        info.update(decision="REFUSE", reason="; ".join(reasons))
        return False, info
    info.update(decision="ALLOW", reason=f"fits: deficit {deficit:.1f} GB, {sysfree:.1f} GB swap headroom")
    return True, info


# --------------------------------------------------------------- main
def main():
    repo = sys.argv[1]
    out_json = sys.argv[2]
    required_peak_gb = float(sys.argv[3]) if len(sys.argv) > 3 else 17.3  # 30B-A3B-4bit measured default
    force = os.environ.get("ESH_FORCE") == "1"
    cap = int(os.environ["ESH_MAX_TOKENS"]) if os.environ.get("ESH_MAX_TOKENS") else None

    allowed, gate = memory_gate(required_peak_gb)
    print("MEMORY GATE:", json.dumps(gate, indent=2), flush=True)
    if not allowed and not force:
        json.dump({"model": repo, "label": "GATED", "memory_gate": gate,
                   "note": "esh MemorySafetyPreflight refused the load; free internal disk / reboot to reclaim swap, "
                           "or set ESH_FORCE=1 to override (not recommended)."},
                  open(out_json, "w"), indent=2)
        print("\nREFUSED by memory gate — no weights loaded. Wrote", out_json)
        return 3

    import mlx.core as mx
    from mlx_lm import load
    from mlx_lm.sample_utils import make_sampler
    try:
        from mlx_lm.generate import stream_generate
    except Exception:
        from mlx_lm.utils import stream_generate

    t_load = time.perf_counter()
    model, tok = load(repo)
    load_s = round(time.perf_counter() - t_load, 2)
    sampler = make_sampler(temp=0.0)

    def render(messages):
        try:
            return tok.apply_chat_template(messages, add_generation_prompt=True, enable_thinking=False)
        except TypeError:
            return tok.apply_chat_template(messages, add_generation_prompt=True)

    def generate(prompt_text, max_tokens):
        text = render([{"role": "user", "content": prompt_text}])
        first = None; n = 0; chunks = []
        t0 = time.perf_counter()
        for r in stream_generate(model, tok, text, max_tokens=max_tokens, sampler=sampler):
            if first is None:
                first = time.perf_counter()
            chunks.append(r.text); n += 1
        return "".join(chunks), (round((first - t0), 2) if first else None), n, first, time.perf_counter()

    def regen(task, turn1_out, follow_user):
        # multi-turn: original user prompt + assistant turn1 + follow-up user
        msgs = [{"role": "user", "content": task["prompt"]},
                {"role": "assistant", "content": turn1_out},
                {"role": "user", "content": follow_user}]
        text = render(msgs)
        chunks = []
        for r in stream_generate(model, tok, text, max_tokens=task["max_tokens"], sampler=sampler):
            chunks.append(r.text)
        return "".join(chunks)

    results = []
    t_all = time.perf_counter()
    for task in suite.TASKS:
        mt = min(task["max_tokens"], cap) if cap else task["max_tokens"]
        out, ttft, n, first, end = generate(task["prompt"], mt)
        ctx = {"regen": regen}
        passed, detail = suite.score(task, out, ctx)
        gen_tps = round((n - 1) / (end - first), 2) if first and n > 1 else None
        row = {"id": task["id"], "category": task["category"], "passed": bool(passed), "detail": detail,
               "ttft_s": ttft, "tokens": n, "gen_tps": gen_tps, "output_head": out[:240]}
        if "turn2_output" in ctx:
            row["turn2_head"] = ctx["turn2_output"]
        results.append(row)
        print(f"[{'PASS' if passed else 'FAIL'}] {task['id']:24s} {str(detail)[:48]:48s} ({gen_tps} tps)", flush=True)

    try:
        peak = round(mx.get_peak_memory() / 1e9, 2)
    except Exception:
        peak = None
    by = {}
    for r in results:
        c = by.setdefault(r["category"], [0, 0]); c[1] += 1; c[0] += int(r["passed"])
    tool_rows = [r for r in results if r["category"] in ("tool_calling", "agent_recovery")]
    summary = {
        "model": repo, "runtime": f"mlx-lm (esh worker engine)", "label": "MEASURED", "temperature": 0,
        "load_seconds": load_s, "peak_memory_gb": peak, "wall_s": round(time.perf_counter() - t_all, 1),
        "passed": sum(r["passed"] for r in results), "total": len(results),
        "by_category": {k: f"{v[0]}/{v[1]}" for k, v in by.items()},
        "tool_call_reliability": f"{sum(r['passed'] for r in tool_rows)}/{len(tool_rows)}" if tool_rows else "n/a",
        "memory_gate": gate, "swap_after": _swapusage(), "results": results,
    }
    json.dump(summary, open(out_json, "w"), indent=2)
    print(f"\n{summary['passed']}/{summary['total']} passed | peak {peak} GB | load {load_s}s | {summary['wall_s']}s")
    print("by category:", summary["by_category"])
    print("tool-call reliability:", summary["tool_call_reliability"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
