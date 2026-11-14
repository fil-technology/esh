#!/usr/bin/env python3
"""Is MLX batched verification batch-invariant? (Phase 3 of the Ghost Infer follow-up.)

Speculative decoding verifies k proposed tokens in ONE forward of k tokens; plain decoding computes each position
with a 1-token forward. ghost-infer makes these bit-identical (fixed reduction order, explicit rounding) so lookup
speculation equals plain greedy exactly. This measures what MLX does: for a real prompt + continuation, logits at
each continuation position are computed (a) by one L-token forward and (b) by L sequential 1-token forwards over the
same cache prefix. Reported per L: bit-identical positions, max |logit diff|, and argmax agreement.

  python benchmarks/diagnose_verify_numerics.py --model <mlx dir> [--lengths 1 2 4 8 16]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    p.add_argument("--lengths", nargs="+", type=int, default=[1, 2, 3, 4, 8, 16])
    p.add_argument("--context", type=int, default=0, help="pad the prompt to about this many tokens")
    a = p.parse_args()

    import mlx.core as mx
    from mlx_lm import load
    from mlx_lm.models.cache import make_prompt_cache

    model, tok = load(a.model)
    code = (Path(__file__).resolve().parent / "fixtures" / "code_edit.swift").read_text()
    prompt = tok.encode("Here is a Swift file:\n" + code[:2500] + "\nRepeat the first function exactly:\n")
    if a.context > len(prompt):
        filler = tok.encode((Path(__file__).resolve().parent / "fixtures" / "long_context.txt").read_text(),
                            add_special_tokens=False)
        pad = (filler * (a.context // max(1, len(filler)) + 1))[: a.context - len(prompt)]
        prompt = pad + prompt
    cont = tok.encode(code[400:1400], add_special_tokens=False)[:max(a.lengths)]

    def prefilled():
        c = make_prompt_cache(model)
        model(mx.array(prompt)[None], cache=c)
        mx.eval([x.state for x in c])
        return c

    report = {"model": a.model, "promptTokens": len(prompt), "dtype": str(model.parameters()["model"]["embed_tokens"]["weight"].dtype)
              if "model" in model.parameters() else None, "byLength": {}}
    for L in a.lengths:
        toks = cont[:L]
        c1 = prefilled()
        batched = model(mx.array(toks)[None], cache=c1)[0].astype(mx.float32)          # (L, V)
        c2 = prefilled()
        seq = mx.concatenate([model(mx.array([t])[None], cache=c2)[0] for t in toks], axis=0).astype(mx.float32)
        diff = mx.abs(batched - seq)
        per_pos_max = mx.max(diff, axis=-1)
        identical = int(mx.sum(per_pos_max == 0).item())
        argmax_eq = int(mx.sum(mx.argmax(batched, -1) == mx.argmax(seq, -1)).item())
        report["byLength"][L] = {
            "bitIdenticalPositions": f"{identical}/{L}",
            "argmaxAgree": f"{argmax_eq}/{L}",
            "maxAbsLogitDiff": round(float(mx.max(diff).item()), 5),
            "meanAbsLogitDiff": round(float(mx.mean(diff).item()), 6),
        }
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
