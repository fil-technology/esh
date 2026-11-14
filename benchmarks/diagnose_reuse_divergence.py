#!/usr/bin/env python3
"""Diagnose WHY a reused-prefix turn differs from a full recompute (numerics vs a real bug).

Runs esh's own generation function (bridge `_generate_with_loaded_model`) in-process for a 4-turn conversation in
two ways: NO reuse (fresh state per turn: whole conversation prefilled at once) and token-exact reuse
(ESH_MLX_PREFIX_CACHE=tokens). At the first token where the outputs diverge it reports, for the SAME token context:
  * the reference path's top-2 logit margin (a tiny margin = a near-tie that floating-point noise can flip)
  * max |logit difference| between a fully recomputed KV and the reused KV (bounded noise vs gross corruption)
A real bug (misaligned positions, duplicated tokens) shows up as large logit differences, not a near-tie.

  python benchmarks/diagnose_reuse_divergence.py --model <mlx dir>
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "Tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
spec = importlib.util.spec_from_file_location("bridge", REPO / "Tools" / "mlx_vlm_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

from validate_prefix_cache import TURNS  # noqa: E402


def run(model, tokenizer, mx, mods, turns, reuse: bool):
    _, stream_generate, KVCache, make_prompt_cache = mods
    os.environ.pop("ESH_MLX_PREFIX_CACHE", None)
    if reuse:
        os.environ["ESH_MLX_PREFIX_CACHE"] = "tokens"
    state = os.path.join(tempfile.mkdtemp(), "s.json")
    msgs, outs = [], []
    for t in turns:
        msgs.append({"role": "user", "text": t})
        sf = state if reuse else os.path.join(tempfile.mkdtemp(), "s.json")
        req = {"modelID": "diag", "kvMode": "raw", "stateFilePath": sf, "session": {"id": "d", "messages": msgs},
               "config": {"maxTokens": 120, "temperature": 0.0, "enableThinking": False}}
        r = bridge._generate_with_loaded_model(mx, stream_generate, KVCache, make_prompt_cache, model, tokenizer,
                                               req, on_token=lambda _t: None)
        msgs.append({"role": "assistant", "text": r["text"]})
        outs.append(r["text"])
    return outs, msgs


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    a = p.parse_args()
    mx, _gs, stream_generate, KVCache, make_prompt_cache, load = bridge._import_mlx_lm()
    model, tokenizer = bridge._load_mlx_model(load, a.model)
    mods = (None, stream_generate, KVCache, make_prompt_cache)

    ref, ref_msgs = run(model, tokenizer, mx, mods, TURNS, reuse=False)
    got, _ = run(model, tokenizer, mx, mods, TURNS, reuse=True)
    report = {"model": a.model, "identicalTurns": [x == y for x, y in zip(ref, got)]}
    turn = next((i for i, (x, y) in enumerate(zip(ref, got)) if x != y), None)
    if turn is None:
        print(json.dumps(report, indent=1)); return

    # token context at the first divergence
    prompt = bridge._render_prompt(tokenizer, [{"role": m["role"], "content": m["text"]} for m in ref_msgs[: 2 * turn + 1]],
                                   add_generation_prompt=True, config={"enableThinking": False})
    ptoks = bridge._tokenize_prompt(tokenizer, prompt)
    ref_ids = tokenizer.encode(ref[turn], add_special_tokens=False)
    got_ids = tokenizer.encode(got[turn], add_special_tokens=False)
    k = next((i for i, (x, y) in enumerate(zip(ref_ids, got_ids)) if x != y), min(len(ref_ids), len(got_ids)))
    ctx = ptoks + ref_ids[:k]

    # (1) full recompute of the whole context in one prefill
    full = make_prompt_cache(model)
    logits_full = model(mx.array(ctx)[None], cache=full)[0, -1].astype(mx.float32)
    # (2) the reuse path's way: previous turns' KV built token-by-token during decode, then the suffix prefilled.
    #     Emulate with the same split the worker used: prefix (all earlier turns' prompt + outputs) step by step.
    prev = bridge._render_prompt(tokenizer, [{"role": m["role"], "content": m["text"]} for m in ref_msgs[: 2 * turn]],
                                 add_generation_prompt=False, config={"enableThinking": False})
    prev_toks = bridge._tokenize_prompt(tokenizer, prev)
    common = bridge._common_prefix_len(prev_toks, ctx)
    inc = make_prompt_cache(model)
    model(mx.array(ctx[: max(1, common // 2)])[None], cache=inc)        # first half as a prompt prefill
    for t in ctx[max(1, common // 2): common]:                          # the rest one token at a time (decode-like)
        model(mx.array([t])[None], cache=inc)
    logits_inc = model(mx.array(ctx[common:])[None], cache=inc)[0, -1].astype(mx.float32)

    top = mx.argsort(-logits_full)[:2].tolist()
    margin = float(logits_full[top[0]] - logits_full[top[1]])
    diff = float(mx.max(mx.abs(logits_full - logits_inc)))
    scale = float(mx.max(mx.abs(logits_full)))
    report.update({
        "firstDivergentTurn": turn, "divergentTokenIndex": k,
        "refToken": tokenizer.decode([ref_ids[k]]) if k < len(ref_ids) else None,
        "reuseToken": tokenizer.decode([got_ids[k]]) if k < len(got_ids) else None,
        "refTop2Margin": round(margin, 4),
        "maxAbsLogitDiffRecomputeVsIncremental": round(diff, 4),
        "maxAbsLogit": round(scale, 2),
        "verdict": "near-tie numeric flip" if margin < max(4 * diff, 0.25) else "NOT a near-tie: investigate",
    })
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
