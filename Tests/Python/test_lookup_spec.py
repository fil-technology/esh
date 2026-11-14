"""Prompt-lookup speculative decoding (EXPERIMENTAL, ESH_MLX_LOOKUP_SPEC=1) — unit + equivalence tests.

The pure-Python tests (index, controller) run anywhere. The equivalence test needs real `mlx` + `mlx_lm` and is
skipped otherwise: on a tiny randomly initialised Llama it checks that lookup speculation yields EXACTLY the
token sequence plain greedy decoding yields, and leaves the KV cache at the same length.

Run: ~/.esh/runtime/py311/venv/bin/python -m unittest Tests/Python/test_lookup_spec.py
"""
from __future__ import annotations

import importlib.util
import sys
import types
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
BRIDGE_PATH = REPOSITORY_ROOT / "Tools" / "mlx_vlm_bridge.py"


def _load_bridge():
    # the bridge imports triattention_runtime at module load; stub it (it pulls mlx) for the pure tests
    if "triattention_runtime" not in sys.modules:
        stub = types.ModuleType("triattention_runtime")
        stub.calibrate_model = lambda *a, **k: None
        stub.maybe_apply_triattention = lambda *a, **k: None
        sys.modules["triattention_runtime"] = stub
    spec = importlib.util.spec_from_file_location("mlx_vlm_bridge_lookup_under_test", BRIDGE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bridge = _load_bridge()


def ensure_real_mlx_lm() -> None:
    """test_mlx_vlm_bridge.py installs stub `mlx_lm` modules in sys.modules and never removes them; drop any stub
    (stubs have no __file__) so the real-MLX tests below import the real package when run in the same process."""
    for name in list(sys.modules):
        if (name == "mlx_lm" or name.startswith("mlx_lm.")) and getattr(sys.modules[name], "__file__", None) is None:
            del sys.modules[name]


class LookupIndexTests(unittest.TestCase):
    def test_never_matches_the_tail_itself(self):
        index = bridge._LookupIndex([5, 6, 7])
        self.assertEqual(index.propose(4, 2), ([], 0))

    def test_proposes_what_followed_the_earlier_occurrence(self):
        # ... 1 2 3 4 5 ... 1 2  -> propose 3 4 5
        index = bridge._LookupIndex([1, 2, 3, 4, 5, 9, 1, 2])
        draft, match = index.propose(3, 2)
        self.assertEqual(draft, [3, 4, 5])
        self.assertEqual(match, 2)

    def test_prefers_the_longest_match_over_the_most_recent(self):
        # occurrence A: 7 1 2 -> 30 (match len 3 with tail "7 1 2"); occurrence B (more recent): 8 1 2 -> 40
        index = bridge._LookupIndex([7, 1, 2, 30, 31, 8, 1, 2, 40, 41, 7, 1, 2])
        draft, match = index.propose(2, 2)
        self.assertEqual(draft, [30, 31])
        self.assertEqual(match, 3)

    def test_min_match_filters_short_matches(self):
        index = bridge._LookupIndex([1, 2, 3, 9, 1, 2])
        self.assertEqual(index.propose(4, 3), ([], 0))

    def test_draft_is_capped(self):
        index = bridge._LookupIndex(list(range(1, 20)) + [1, 2])
        draft, _ = index.propose(5, 2)
        self.assertEqual(draft, [3, 4, 5, 6, 7])


class LookupPaceTests(unittest.TestCase):
    def test_no_verify_when_verification_is_expensive_and_guesses_are_poor(self):
        pace = bridge._LookupPace(16)
        pace.step_s = 0.03
        pace.verify_s = {k: 0.03 * (1 + 0.9 * k) for k in range(2, 18)}
        pace.acc = [[0.05, 4.0] for _ in pace.acc]
        self.assertEqual(pace.choose(8, 3), 0)

    def test_verifies_long_drafts_when_cheap_and_accurate(self):
        pace = bridge._LookupPace(16)
        pace.step_s = 0.03
        pace.verify_s = {k: 0.03 * (1 + 0.04 * k) for k in range(2, 18)}
        pace.acc = [[3.8, 4.0] for _ in pace.acc]
        self.assertGreaterEqual(pace.choose(12, 10), 8)

    def test_backs_off_when_realized_speculation_loses(self):
        pace = bridge._LookupPace(16)
        pace.step_s = 0.03
        for _ in range(8):  # each round: 2 tokens for 0.03 + 0.2 s  -> far below plain's 33 tok/s
            pace.note_verify(4, 0.2, 3, 3, 0, 2, produced=100)
        self.assertFalse(pace.active(110))
        self.assertTrue(pace.active(100 + 16))


class SettingsGateTests(unittest.TestCase):
    def test_off_unless_flagged(self):
        self.assertIsNone(bridge._lookup_spec_settings({"temperature": 0.0}, [], None))

    def test_sampled_decoding_falls_back(self):
        import os
        os.environ["ESH_MLX_LOOKUP_SPEC"] = "1"
        try:
            self.assertIsNone(bridge._lookup_spec_settings({"temperature": 0.7}, [], None))
            self.assertIsNone(bridge._lookup_spec_settings({"temperature": 0.0, "repetitionPenalty": 1.1}, [], None))
        finally:
            del os.environ["ESH_MLX_LOOKUP_SPEC"]


try:
    import mlx.core as mx  # noqa: F401
    from mlx_lm.models import llama
    HAVE_MLX = True
except Exception:  # noqa: BLE001
    HAVE_MLX = False


class _Detok:
    def __init__(self):
        self.tokens = []
        self.last_segment = ""

    def reset(self):
        self.tokens = []

    def add_token(self, t):
        self.tokens.append(t)
        self.last_segment = f"<{t}>"

    def finalize(self):
        self.last_segment = ""


class _Tok:
    eos_token_ids = [0]

    def __init__(self):
        self.last = _Detok()

    @property
    def detokenizer(self):
        return self.last


@unittest.skipUnless(HAVE_MLX, "needs mlx + mlx_lm")
class GreedyEquivalenceTests(unittest.TestCase):
    def setUp(self):
        ensure_real_mlx_lm()

    def _model(self):
        import mlx.core as mx
        mx.random.seed(7)
        args = llama.ModelArgs(model_type="llama", hidden_size=64, num_hidden_layers=2, intermediate_size=128,
                               num_attention_heads=4, rms_norm_eps=1e-5, vocab_size=97, num_key_value_heads=2)
        model = llama.Model(args)
        mx.eval(model.parameters())
        return model

    def test_lookup_matches_plain_greedy_tokens_and_cache_length(self):
        import mlx.core as mx
        from mlx_lm.generate import generate_step
        from mlx_lm.models.cache import make_prompt_cache

        model = self._model()
        # a repetitive prompt so the index proposes drafts
        prompt = ([5, 9, 13, 21, 34, 55, 8, 13] * 6) + [5, 9, 13]
        n = 60

        cache_a = make_prompt_cache(model)
        plain = []
        for tok, _ in generate_step(mx.array(prompt), model, max_tokens=n, prompt_cache=cache_a,
                                    sampler=lambda x: mx.argmax(x, axis=-1)):
            t = int(tok)
            if t == 0:
                break
            plain.append(t)

        cache_b = make_prompt_cache(model)
        stats = {}
        settings = {"maxDraft": 8, "minMatch": 2, "adaptive": False}
        tok = _Tok()
        for _ in bridge._lookup_stream_generate(mx, model, tok, prompt, list(prompt), n, cache_b, settings, stats):
            pass
        spec = tok.last.tokens  # exactly what the bridge's text comes from

        self.assertEqual(spec, plain[: len(spec)])
        self.assertEqual(len(spec), len(plain))
        self.assertGreater(stats["verifySteps"], 0, "test prompt should exercise verification")
        self.assertEqual(cache_a[0].offset, cache_b[0].offset)


if __name__ == "__main__":
    unittest.main()
