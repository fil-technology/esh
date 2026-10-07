#!/usr/bin/env python3
"""Phase-C: run an MLX LLM and MEASURE prompt tok/s, generation tok/s, TTFT, peak memory, with a memory-safety
guard (brief §19). Weights download to the SSD HF cache (HF_HOME set by caller). Prints JSON.

Usage: bench_mlx_lm.py <hf_repo> <max_tokens> [prompt]
"""
import sys, os, json, time
import mlx.core as mx


def avail_mem_mb():
    import subprocess, re
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
        pg = 16384
        free = re.search(r"Pages free:\s+(\d+)", out)
        spec = re.search(r"Pages speculative:\s+(\d+)", out)
        inactive = re.search(r"Pages inactive:\s+(\d+)", out)
        mb = 0
        for m in (free, spec, inactive):
            if m: mb += int(m.group(1)) * pg
        return mb / 1e6
    except Exception:
        return None


def main():
    repo = sys.argv[1]
    max_tokens = int(sys.argv[2]) if len(sys.argv) > 2 else 128
    prompt = sys.argv[3] if len(sys.argv) > 3 else \
        "Write a Swift function that debounces an async throwing operation, and explain the concurrency model in 3 sentences."
    out = {"model": repo, "max_tokens": max_tokens, "label": "MEASURED"}

    # Safety guard: refuse if too little memory free right now.
    before = avail_mem_mb()
    out["avail_mem_mb_before"] = round(before, 0) if before else None
    MIN_FREE = float(os.environ.get("ESH_MIN_FREE_MB", "4000"))
    if before is not None and before < MIN_FREE:
        print(json.dumps({**out, "error": f"aborted: only {before:.0f} MB free, need {MIN_FREE:.0f}"}))
        return

    from mlx_lm import load
    try:
        from mlx_lm.generate import stream_generate
    except Exception:
        from mlx_lm.utils import stream_generate

    t0 = time.perf_counter()
    model, tok = load(repo)
    out["load_seconds"] = round(time.perf_counter() - t0, 2)

    # Build chat prompt if a template exists.
    try:
        messages = [{"role": "user", "content": prompt}]
        text = tok.apply_chat_template(messages, add_generation_prompt=True)
    except Exception:
        text = prompt

    n_prompt = None; first_tok_t = None; n_gen = 0; gen_text = []
    tg0 = time.perf_counter()
    last = None
    for resp in stream_generate(model, tok, text, max_tokens=max_tokens):
        if first_tok_t is None:
            first_tok_t = time.perf_counter()
        n_gen += 1
        gen_text.append(getattr(resp, "text", ""))
        last = resp
    tg1 = time.perf_counter()

    # Prefer library-reported metrics when present (they separate prefill vs decode cleanly).
    for attr, key in [("prompt_tokens", "prompt_tokens"), ("prompt_tps", "prompt_tps"),
                      ("generation_tokens", "generation_tokens"), ("generation_tps", "generation_tps"),
                      ("peak_memory", "peak_memory_gb")]:
        v = getattr(last, attr, None)
        if v is not None:
            out[key] = round(v, 3) if "tps" in key or "gb" in key else v

    out["ttft_seconds"] = round((first_tok_t - tg0), 3) if first_tok_t else None
    out["wall_generate_seconds"] = round(tg1 - tg0, 2)
    out["tokens_generated"] = n_gen
    if "generation_tps" not in out and first_tok_t:
        # decode-only tps = (n_gen-1) tokens over (end - first_token)
        dt = tg1 - first_tok_t
        out["generation_tps_measured"] = round((n_gen - 1) / dt, 2) if dt > 0 and n_gen > 1 else None
    try:
        out["peak_memory_gb"] = round(mx.get_peak_memory() / 1e9, 2)
    except Exception:
        try: out["peak_memory_gb"] = round(mx.metal.get_peak_memory() / 1e9, 2)
        except Exception: pass
    out["avail_mem_mb_after"] = round(avail_mem_mb() or 0, 0)
    out["sample_output"] = ("".join(gen_text))[:600]
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
