"""Token-exact prefix reuse (EXPERIMENTAL, ESH_MLX_PREFIX_CACHE=tokens|live).

Pure tests cover the longest-common-prefix logic; the MLX tests (skipped without mlx/mlx_lm) run two "turns" on a
tiny random Llama and require that continuing from the reused, trimmed cache yields EXACTLY the tokens a full
recomputation yields — for both the snapshot ("tokens") and in-memory ("live") modes, including a second prompt
that diverges inside the cached region (the Qwen3 <think> / Llama-3 header case).

Run: ~/.esh/runtime/py311/venv/bin/python -m unittest Tests/Python/test_prefix_cache.py
"""
from __future__ import annotations

import os
import tempfile
import unittest

from test_lookup_spec import bridge  # noqa: E402  (shared loader that stubs triattention_runtime)

try:
    import mlx.core as mx
    from mlx_lm.generate import generate_step
    from mlx_lm.models import llama
    from mlx_lm.models.cache import KVCache, make_prompt_cache
    HAVE_MLX = True
except Exception:  # noqa: BLE001
    HAVE_MLX = False


class CommonPrefixTests(unittest.TestCase):
    def test_common_prefix(self):
        self.assertEqual(bridge._common_prefix_len([1, 2, 3, 4], [1, 2, 9]), 2)
        self.assertEqual(bridge._common_prefix_len([], [1]), 0)
        self.assertEqual(bridge._common_prefix_len([1, 2], [1, 2, 3]), 2)

    def test_mode_defaults_to_legacy(self):
        os.environ.pop("ESH_MLX_PREFIX_CACHE", None)
        self.assertEqual(bridge._prefix_cache_mode(), "legacy")
        os.environ["ESH_MLX_PREFIX_CACHE"] = "bogus"
        try:
            self.assertEqual(bridge._prefix_cache_mode(), "legacy")
        finally:
            del os.environ["ESH_MLX_PREFIX_CACHE"]


@unittest.skipUnless(HAVE_MLX, "needs mlx + mlx_lm")
class PrefixReuseEquivalenceTests(unittest.TestCase):
    def setUp(self):
        mx.random.seed(3)
        args = llama.ModelArgs(model_type="llama", hidden_size=64, num_hidden_layers=2, intermediate_size=128,
                               num_attention_heads=4, rms_norm_eps=1e-5, vocab_size=97, num_key_value_heads=2)
        self.model = llama.Model(args)
        mx.eval(self.model.parameters())
        bridge._LIVE_PREFIX_CACHES.clear()

    def _greedy(self, prompt, cache, n=12):
        out = []
        for tok, _ in generate_step(mx.array(prompt), self.model, max_tokens=n, prompt_cache=cache,
                                    sampler=lambda x: mx.argmax(x, axis=-1)):
            out.append(int(tok))
        return out

    def _turns(self, mode):
        state = os.path.join(tempfile.mkdtemp(), "state.json")
        turn1 = list(range(10, 40))                    # 30-token "conversation"
        cache = make_prompt_cache(self.model)
        gen1 = self._greedy(turn1, cache)
        payload = bridge._finish_token_prefix(mode, state, cache, turn1 + gen1, {"model_id": "t"})
        bridge._save_state_file(state, {k: v for k, v in payload.items() if k != "metadata"})

        # turn 2 diverges INSIDE the cached region (position 25), like a template that rewrites history
        turn2 = turn1[:25] + [77, 78, 79] + list(range(50, 60))
        reused_cache, to_prefill, hit, reused = bridge._token_prefix_reuse(
            mode, state, bridge._load_state_file(state), turn2, make_prompt_cache, self.model, KVCache)
        self.assertTrue(hit)
        self.assertEqual(reused, 25)
        self.assertEqual(to_prefill, turn2[25:])
        got = self._greedy(to_prefill, reused_cache)

        fresh = self._greedy(turn2, make_prompt_cache(self.model))
        self.assertEqual(got, fresh)

    def test_snapshot_mode_is_exact(self):
        self._turns("tokens")

    def test_live_mode_is_exact(self):
        self._turns("live")

    def test_short_overlap_is_a_miss(self):
        state = os.path.join(tempfile.mkdtemp(), "state.json")
        cache = make_prompt_cache(self.model)
        turn1 = list(range(10, 30))
        gen1 = self._greedy(turn1, cache, n=4)
        payload = bridge._finish_token_prefix("tokens", state, cache, turn1 + gen1, {})
        bridge._save_state_file(state, {k: v for k, v in payload.items() if k != "metadata"})
        _, to_prefill, hit, reused = bridge._token_prefix_reuse(
            "tokens", state, bridge._load_state_file(state), [10, 11, 12, 90, 91, 92, 93, 94, 95, 96],
            make_prompt_cache, self.model, KVCache)
        self.assertFalse(hit)
        self.assertEqual(reused, 0)


if __name__ == "__main__":
    unittest.main()
