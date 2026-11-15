"""Token-exact prefix reuse (default `tokens`; `live` opt-in; `legacy` explicit rollback).

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

from test_lookup_spec import bridge, ensure_real_mlx_lm  # noqa: E402  (shared loader)

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

    def _mode(self, env_value, in_worker, budget=None):
        from unittest import mock
        os.environ.pop("ESH_MLX_PREFIX_CACHE", None)
        if env_value is not None:
            os.environ["ESH_MLX_PREFIX_CACHE"] = env_value
        patches = [mock.patch.object(bridge, "_IN_PERSISTENT_WORKER", in_worker)]
        if budget is not None:
            patches.append(mock.patch.object(bridge, "_live_cache_budget_bytes", return_value=budget))
        try:
            for p in patches:
                p.start()
            return bridge._prefix_cache_mode()
        finally:
            for p in patches:
                p.stop()
            os.environ.pop("ESH_MLX_PREFIX_CACHE", None)

    def test_one_shot_paths_default_to_tokens_and_never_run_live(self):
        self.assertEqual(self._mode(None, False), "tokens")
        self.assertEqual(self._mode("bogus", False), "tokens")
        self.assertEqual(self._mode("LIVE", False), "tokens")      # live needs a process that outlives the request
        self.assertEqual(self._mode("legacy", False), "legacy")

    def test_persistent_worker_defaults_to_live_with_explicit_rollback(self):
        self.assertEqual(self._mode(None, True), "live")
        self.assertEqual(self._mode(" bogus ", True), "live")
        self.assertEqual(self._mode("tokens", True), "tokens")     # rollback
        self.assertEqual(self._mode("legacy", True), "legacy")     # pre-2026-11 path

    def test_live_without_a_cache_budget_runs_token_exact(self):
        self.assertEqual(self._mode(None, True, budget=0), "tokens")


@unittest.skipUnless(HAVE_MLX, "needs mlx + mlx_lm")
class PrefixReuseEquivalenceTests(unittest.TestCase):
    def _state_path(self) -> str:
        """A state-file path in a temp directory removed after the test (with its KV sidecars)."""
        tmp = tempfile.TemporaryDirectory(prefix="esh-prefix-test-")
        self.addCleanup(tmp.cleanup)
        return os.path.join(tmp.name, "state.json")

    def setUp(self):
        ensure_real_mlx_lm()
        mx.random.seed(3)
        # These tests exercise snapshot behavior, not the host's free disk: the disk guard (tested on its own in
        # SnapshotDiskGuardTests) would otherwise skip snapshots on a nearly full development machine.
        from unittest import mock
        patcher = mock.patch.object(bridge, "_snapshot_skip_reason", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)
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
        state = self._state_path()
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

    def test_skipped_snapshot_is_a_clean_miss(self):
        from unittest import mock
        state = self._state_path()
        cache = make_prompt_cache(self.model)
        turn1 = list(range(10, 40))
        gen1 = self._greedy(turn1, cache, n=4)
        with mock.patch.object(bridge, "_snapshot_skip_reason", return_value="KV snapshot skipped: test"):
            payload = bridge._finish_token_prefix("tokens", state, cache, turn1 + gen1, {})
        self.assertIsNone(payload["snapshot"])
        bridge._save_state_file(state, {k: v for k, v in payload.items() if k != "metadata"})
        _, to_prefill, hit, _ = bridge._token_prefix_reuse(
            "tokens", state, bridge._load_state_file(state), turn1 + gen1 + [5, 6], make_prompt_cache, self.model, KVCache)
        self.assertFalse(hit)
        self.assertEqual(len(to_prefill), len(turn1) + len(gen1) + 2)

    def _finish_live(self, key, prompt, n=4, state=None):
        state = state or self._state_path()
        cache = make_prompt_cache(self.model)
        gen = self._greedy(prompt, cache, n=n)
        bridge._finish_token_prefix("live", state, cache, prompt + gen, {}, cache_key=key)
        return state, prompt + gen

    def test_stateless_interleaved_conversations_each_find_their_own_cache(self):
        # esh serve / OpenAI clients: no session ids, every request resends the conversation
        state = self._state_path()
        bridge._LAST_LIVE_SLOT = None
        _, a_tokens = self._finish_live(None, list(range(10, 40)), state=state)
        bridge._LAST_LIVE_SLOT = None
        _, b_tokens = self._finish_live(None, list(range(50, 80)), state=state)
        self.assertEqual(len(bridge._LIVE_PREFIX_CACHES), 2)
        cache, to_prefill, hit, reused = bridge._token_prefix_reuse(
            "live", state, None, b_tokens + [5, 6], make_prompt_cache, self.model, KVCache)
        self.assertTrue(hit)
        self.assertEqual(reused, len(b_tokens))           # B continued from B's cache, not A's
        remaining = [t for t, _ in bridge._LIVE_PREFIX_CACHES.values()]
        self.assertEqual(remaining, [a_tokens])            # A's cache untouched while B generates
        # continuing from the reused cache equals a full recompute of B's conversation
        self.assertEqual(self._greedy(to_prefill, cache, n=4),
                         self._greedy(b_tokens + [5, 6], make_prompt_cache(self.model), n=4))

    def test_reuse_across_conversations_is_limited_to_identical_tokens(self):
        state = self._state_path()
        bridge._LAST_LIVE_SLOT = None
        _, a_tokens = self._finish_live(None, list(range(10, 40)), state=state)
        other = a_tokens[:20] + [90, 91, 92, 93]            # shares only the first 20 tokens (a system prompt)
        cache, to_prefill, hit, reused = bridge._token_prefix_reuse(
            "live", state, None, other, make_prompt_cache, self.model, KVCache)
        self.assertTrue(hit)
        self.assertEqual(reused, 20)
        self.assertEqual(self._greedy(to_prefill, cache, n=4),
                         self._greedy(other, make_prompt_cache(self.model), n=4))

    def test_explicit_key_is_preferred(self):
        state = self._state_path()
        self._finish_live("key:A", list(range(10, 40)), state=state)
        self._finish_live("key:B", list(range(10, 40)), state=state)   # identical content, different key
        _, _, hit, _ = bridge._token_prefix_reuse(
            "live", state, None, list(range(10, 45)), make_prompt_cache, self.model, KVCache, cache_key="key:B")
        self.assertTrue(hit)
        self.assertEqual(list(bridge._LIVE_PREFIX_CACHES), ["key:A"])

    def test_an_in_flight_cache_is_owned_by_its_request(self):
        state, a_tokens = self._finish_live("session:A", list(range(10, 40)))
        cache, _, hit, _ = bridge._token_prefix_reuse(
            "live", state, None, a_tokens + [5, 6], make_prompt_cache, self.model, KVCache, cache_key="session:A")
        self.assertTrue(hit)
        # while the request runs, a drop (pressure / pool eviction) cannot reach its cache: it was popped
        self.assertNotIn("session:A", bridge._LIVE_PREFIX_CACHES)
        bridge._drop_live_caches()
        out = self._greedy([5, 6], cache, n=3)
        self.assertEqual(len(out), 3)

    def test_drop_releases_everything_and_reports_bytes(self):
        self._finish_live("session:A", list(range(10, 40)))
        held = bridge._live_cache_resident_bytes()
        self.assertGreater(held, 0)
        self.assertEqual(bridge._drop_live_caches(), held)
        self.assertEqual(bridge._live_cache_resident_bytes(), 0)

    def test_live_budget_is_enforced(self):
        os.environ["ESH_MLX_LIVE_PREFIX_MAX_BYTES"] = "1"
        try:
            state = self._state_path()
            cache = make_prompt_cache(self.model)
            prompt = list(range(10, 40))
            gen = self._greedy(prompt, cache, n=4)
            payload = bridge._finish_token_prefix("live", state, cache, prompt + gen, {}, cache_key="session:A")
            self.assertIn("exceeds the live-cache budget", payload.get("liveNotRetained", ""))
            self.assertEqual(bridge._LIVE_PREFIX_CACHES, {})
        finally:
            del os.environ["ESH_MLX_LIVE_PREFIX_MAX_BYTES"]

    def test_slot_limit_evicts_least_recent_session(self):
        os.environ["ESH_MLX_LIVE_PREFIX_SLOTS"] = "2"
        try:
            state = self._state_path()
            for key in ("session:A", "session:B", "session:C"):
                self._finish_live(key, list(range(10, 30)), state=state)
            self.assertEqual(list(bridge._LIVE_PREFIX_CACHES), ["session:B", "session:C"])
        finally:
            del os.environ["ESH_MLX_LIVE_PREFIX_SLOTS"]

    def test_live_that_cannot_retain_falls_back_to_a_token_exact_snapshot(self):
        os.environ["ESH_MLX_LIVE_PREFIX_MAX_BYTES"] = "1"
        try:
            state = self._state_path()
            cache = make_prompt_cache(self.model)
            turn = list(range(10, 40))
            gen = self._greedy(turn, cache, n=4)
            payload = bridge._finish_token_prefix("live", state, cache, turn + gen, {"model_id": "m"})
            self.assertIn("exceeds the live-cache budget", payload["liveNotRetained"])
            self.assertEqual(payload["snapshot"]["format"], "mlx-cache-sidecar-v1")   # fell back to tokens
            bridge._save_state_file(state, {k: v for k, v in payload.items() if k != "metadata"})
            # the next live turn misses the (empty) live slots but reuses the token-exact snapshot
            reused, to_prefill, hit, n = bridge._token_prefix_reuse(
                "live", state, bridge._load_state_file(state), turn + gen + [1, 2], make_prompt_cache, self.model,
                KVCache, model_id="m")
            self.assertTrue(hit)
            self.assertEqual(n, len(turn + gen))
            self.assertEqual(self._greedy(to_prefill, reused, n=4),
                             self._greedy(turn + gen + [1, 2], make_prompt_cache(self.model), n=4))
        finally:
            del os.environ["ESH_MLX_LIVE_PREFIX_MAX_BYTES"]

    def test_non_trimmable_caches_are_not_retained(self):
        from mlx_lm.models.cache import RotatingKVCache
        state = self._state_path()
        cache = [RotatingKVCache(max_size=8) for _ in self.model.layers]
        prompt = list(range(10, 40))
        gen = self._greedy(prompt, cache, n=4)
        payload = bridge._finish_token_prefix("live", state, cache, prompt + gen, {}, cache_key="session:R")
        self.assertIn("not trimmable", payload.get("liveNotRetained", ""))
        self.assertNotIn("session:R", bridge._LIVE_PREFIX_CACHES)

    def test_session_cache_key(self):
        # per-request ChatSession ids are random in esh's request paths: never part of the key
        self.assertIsNone(bridge._session_cache_key({"session": {"id": "abc"}, "stateFilePath": "/s"}))
        explicit = bridge._session_cache_key({"prefixCacheKey": "agent-1"})
        self.assertTrue(explicit.startswith("key:agent-1#"))
        in_config = bridge._session_cache_key({"config": {"prefixCacheKey": "agent-1"}})
        self.assertEqual(explicit, in_config)

    @staticmethod
    def _req(messages, **extra):
        return {"modelID": "m", "kvMode": "raw", "session": {"id": "random", "messages": messages}, **extra}

    def test_conversation_identity_is_stable_across_turns_and_distinct_between_conversations(self):
        sys_msg = {"role": "system", "text": "You are terse."}
        a1 = self._req([sys_msg, {"role": "user", "text": "Hello A"}])
        a3 = self._req([sys_msg, {"role": "user", "text": "Hello A"}, {"role": "assistant", "text": "Hi"},
                        {"role": "user", "text": "More"}])
        a3["session"]["id"] = "another-random-id"            # a new ChatSession per request, as esh builds them
        b1 = self._req([sys_msg, {"role": "user", "text": "Hello B"}])
        self.assertEqual(bridge._session_cache_key(a1), bridge._session_cache_key(a3))
        self.assertNotEqual(bridge._session_cache_key(a1), bridge._session_cache_key(b1))
        # OpenAI-style "content" keys derive the same identity as "text"
        self.assertEqual(bridge._session_cache_key(a1), bridge._session_cache_key(
            self._req([{"role": "system", "content": "You are terse."}, {"role": "user", "content": "Hello A"}])))

    def test_kv_layout_or_model_change_changes_the_key(self):
        base = self._req([{"role": "user", "text": "Hi"}], config={"maxTokens": 8})
        same = self._req([{"role": "user", "text": "Hi"}], config={"maxTokens": 99, "temperature": 0.9})
        quant = self._req([{"role": "user", "text": "Hi"}], config={"kvBits": 4})
        other_model = {**base, "modelID": "other"}
        self.assertEqual(bridge._session_cache_key(base), bridge._session_cache_key(same))  # sampling: no effect
        self.assertNotEqual(bridge._session_cache_key(base), bridge._session_cache_key(quant))
        self.assertNotEqual(bridge._session_cache_key(base), bridge._session_cache_key(other_model))

    def test_a_new_conversation_borrows_a_shared_prefix_without_touching_the_donor(self):
        import numpy as np
        state = self._state_path()
        _, a_tokens = self._finish_live("conv:A#L", list(range(10, 40)), state=state)
        donor_tokens, donor_cache = bridge._LIVE_PREFIX_CACHES["conv:A#L"]
        before = [np.array(layer.state[0]) for layer in donor_cache]
        b_prompt = a_tokens[:20] + [90, 91, 92, 93]          # shares a 20-token preamble with A
        cache, to_prefill, hit, reused = bridge._token_prefix_reuse(
            "live", state, None, b_prompt, make_prompt_cache, self.model, KVCache, cache_key="conv:B#L")
        self.assertTrue(hit)
        self.assertEqual(reused, 20)
        self.assertEqual(bridge._LAST_PREFIX_SOURCE, "borrowed")
        got = self._greedy(to_prefill, cache, n=4)           # B generates on its copy
        self.assertEqual(got, self._greedy(b_prompt, make_prompt_cache(self.model), n=4))
        # A's slot is still there, with the same tokens and the same KV values
        self.assertIn("conv:A#L", bridge._LIVE_PREFIX_CACHES)
        tokens_after, cache_after = bridge._LIVE_PREFIX_CACHES["conv:A#L"]
        self.assertEqual(tokens_after, donor_tokens)
        for b, layer in zip(before, cache_after):
            self.assertTrue(np.array_equal(b, np.array(layer.state[0])))
        # and A continues from its own slot
        _, _, hit_a, reused_a = bridge._token_prefix_reuse(
            "live", state, None, a_tokens + [5], make_prompt_cache, self.model, KVCache, cache_key="conv:A#L")
        self.assertTrue(hit_a)
        self.assertEqual(reused_a, len(a_tokens))

    def test_no_borrowing_across_kv_layouts(self):
        state = self._state_path()
        _, a_tokens = self._finish_live("conv:A#L1", list(range(10, 40)), state=state)
        _, _, hit, _ = bridge._token_prefix_reuse(
            "live", state, None, a_tokens[:20] + [90, 91], make_prompt_cache, self.model, KVCache, cache_key="conv:B#L2")
        self.assertFalse(hit)
        self.assertIn("conv:A#L1", bridge._LIVE_PREFIX_CACHES)

    def test_borrowing_respects_the_live_budget(self):
        from unittest import mock
        state = self._state_path()
        _, a_tokens = self._finish_live("conv:A#L", list(range(10, 40)), state=state)
        held = bridge._live_cache_resident_bytes()
        with mock.patch.object(bridge, "_live_cache_budget_bytes", return_value=held):   # no room for a copy
            _, to_prefill, hit, _ = bridge._token_prefix_reuse(
                "live", state, None, a_tokens[:20] + [90, 91], make_prompt_cache, self.model, KVCache,
                cache_key="conv:B#L")
        self.assertFalse(hit)
        self.assertEqual(len(to_prefill), 22)                # full prefill fallback

    def test_interleaved_conversations_beyond_two_keep_their_own_slots(self):
        # issue #38: 3 conversations interleaved turn by turn used to thrash 2 LRU slots (0% reuse)
        state = self._state_path()
        history = {k: list(range(start, start + 20)) for k, start in (("conv:A#L", 10), ("conv:B#L", 40),
                                                                      ("conv:C#L", 70))}
        for key, toks in history.items():
            _, history[key] = self._finish_live(key, toks, state=state)
        for _round in range(2):
            for key in history:
                prompt = history[key] + [3, 4]
                cache, to_prefill, hit, reused = bridge._token_prefix_reuse(
                    "live", state, None, prompt, make_prompt_cache, self.model, KVCache, cache_key=key)
                self.assertTrue(hit, key)
                self.assertEqual(reused, len(history[key]))
                self.assertEqual(bridge._LAST_PREFIX_SOURCE, "own")
                gen = self._greedy(to_prefill, cache, n=2)
                bridge._finish_token_prefix("live", state, cache, prompt + gen, {}, cache_key=key)
                history[key] = prompt + gen
        self.assertEqual(set(bridge._LIVE_PREFIX_CACHES), set(history))

    def test_more_conversations_than_slots_evicts_lru_and_misses_cleanly(self):
        os.environ["ESH_MLX_LIVE_PREFIX_SLOTS"] = "2"
        try:
            state = self._state_path()
            toks = {}
            for key, start in (("conv:A#L", 10), ("conv:B#L", 40), ("conv:C#L", 70)):
                _, toks[key] = self._finish_live(key, list(range(start, start + 20)), state=state)
            self.assertEqual(list(bridge._LIVE_PREFIX_CACHES), ["conv:B#L", "conv:C#L"])   # A was least recent
            prompt = toks["conv:A#L"] + [3]
            cache, to_prefill, hit, _ = bridge._token_prefix_reuse(
                "live", state, None, prompt, make_prompt_cache, self.model, KVCache, cache_key="conv:A#L")
            self.assertFalse(hit)                            # evicted: full prefill, still exact
            self.assertEqual(self._greedy(to_prefill, cache, n=3),
                             self._greedy(prompt, make_prompt_cache(self.model), n=3))
        finally:
            del os.environ["ESH_MLX_LIVE_PREFIX_SLOTS"]

    def test_a_failed_request_leaves_no_partial_slot(self):
        state, a_tokens = self._finish_live("conv:A#L", list(range(10, 40)))
        cache, _, hit, _ = bridge._token_prefix_reuse(
            "live", state, None, a_tokens + [5], make_prompt_cache, self.model, KVCache, cache_key="conv:A#L")
        self.assertTrue(hit)
        # the request fails here: _finish_token_prefix is never called for it
        self.assertNotIn("conv:A#L", bridge._LIVE_PREFIX_CACHES)
        prompt = a_tokens + [5, 6]
        cache2, to_prefill, hit2, _ = bridge._token_prefix_reuse(
            "live", state, None, prompt, make_prompt_cache, self.model, KVCache, cache_key="conv:A#L")
        self.assertFalse(hit2)                               # next turn: clean full prefill
        self.assertEqual(self._greedy(to_prefill, cache2, n=3),
                         self._greedy(prompt, make_prompt_cache(self.model), n=3))

    def test_tokens_mode_keeps_exactly_one_sidecar_referenced_by_the_state(self):
        state = self._state_path()
        cache = make_prompt_cache(self.model)
        turn = list(range(10, 40))
        gen = self._greedy(turn, cache, n=4)
        first = bridge._finish_token_prefix("tokens", state, cache, turn + gen, {})
        second = bridge._finish_token_prefix("tokens", state, cache, turn + gen, {})
        sidecars = bridge._kv_sidecar_paths(state)
        self.assertEqual(sidecars, [second["snapshot"]["path"]])
        self.assertNotEqual(first["snapshot"]["path"], second["snapshot"]["path"])
        self.assertNotIn("mlx_prompt_cache_safetensors_base64", second["snapshot"]["metadata"])
        # switching the same state file to live mode drops the now-meaningless sidecar
        bridge._finish_token_prefix("live", state, cache, turn + gen, {}, cache_key="session:Z")
        self.assertEqual(bridge._kv_sidecar_paths(state), [])

    def test_snapshot_from_another_model_is_never_restored(self):
        state = self._state_path()
        cache = make_prompt_cache(self.model)
        turn = list(range(10, 40))
        gen = self._greedy(turn, cache, n=4)
        payload = bridge._finish_token_prefix("tokens", state, cache, turn + gen, {"model_id": "model-A"})
        bridge._save_state_file(state, {k: v for k, v in payload.items() if k != "metadata"})
        loaded = bridge._load_state_file(state)
        _, _, hit, _ = bridge._token_prefix_reuse("tokens", state, loaded, turn + gen + [1, 2], make_prompt_cache,
                                                  self.model, KVCache, model_id="model-B")
        self.assertFalse(hit)
        _, _, hit, _ = bridge._token_prefix_reuse("tokens", state, loaded, turn + gen + [1, 2], make_prompt_cache,
                                                  self.model, KVCache, model_id="model-A")
        self.assertTrue(hit)

    def test_quantized_kv_cache_snapshots_round_trip(self):
        # regression: legacy snapshots of a QuantizedKVCache (kvBits) crashed converting bf16 scales to numpy
        args = llama.ModelArgs(model_type="llama", hidden_size=128, num_hidden_layers=2, intermediate_size=256,
                               num_attention_heads=4, rms_norm_eps=1e-5, vocab_size=97, num_key_value_heads=2)
        model = llama.Model(args)   # head width 32: the smallest MLX quantization group
        mx.eval(model.parameters())
        cache = make_prompt_cache(model)
        model(mx.array(list(range(10, 90)))[None], cache=cache)
        mx.eval([c.state for c in cache])
        qcache = [c.to_quantized(group_size=32, bits=8) for c in cache]
        snap = bridge._prompt_cache_to_snapshot(qcache, {"model_id": "t"})
        self.assertGreater(int(snap["metadata"]["raw_bytes"]), 0)
        self.assertIn("mlx_prompt_cache_safetensors_base64", snap["metadata"])
        restored = bridge._snapshot_to_prompt_cache(snap, KVCache)
        self.assertEqual(type(restored[0]).__name__, "QuantizedKVCache")
        self.assertEqual(restored[0].offset, qcache[0].offset)
        self.assertEqual(bridge._kv_raw_bytes(qcache), int(snap["metadata"]["raw_bytes"]))

    def test_short_overlap_is_a_miss(self):
        state = self._state_path()
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
