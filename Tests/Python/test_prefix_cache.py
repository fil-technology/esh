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

    def test_mode_defaults_to_legacy(self):
        os.environ.pop("ESH_MLX_PREFIX_CACHE", None)
        self.assertEqual(bridge._prefix_cache_mode(), "legacy")
        os.environ["ESH_MLX_PREFIX_CACHE"] = "bogus"
        try:
            self.assertEqual(bridge._prefix_cache_mode(), "legacy")
        finally:
            del os.environ["ESH_MLX_PREFIX_CACHE"]


class CrashSafeTempFileTests(unittest.TestCase):
    def test_sweep_removes_only_dead_owners(self):
        import subprocess
        d = tempfile.mkdtemp()
        dead = subprocess.Popen(["true"]); dead.wait()          # a pid that has exited
        live = os.getppid()
        for name in (f"{dead.pid}-old.json", f"{live}-other.json", f"{os.getpid()}-mine.json", "notes.txt"):
            open(os.path.join(d, name), "w").close()
        os.makedirs(os.path.join(d, f"{dead.pid}-stagingdir"))
        removed = bridge._sweep_dead_owner_entries(d)
        self.assertEqual(sorted(removed), sorted([f"{dead.pid}-old.json", f"{dead.pid}-stagingdir"]))
        self.assertEqual(sorted(os.listdir(d)), sorted([f"{live}-other.json", f"{os.getpid()}-mine.json", "notes.txt"]))

    def test_staging_dirs_are_owner_tagged_and_removed(self):
        with bridge._StagingDir() as path:
            self.assertTrue(os.path.basename(path).startswith(f"{os.getpid()}-"))
            self.assertTrue(os.path.isdir(path))
        self.assertFalse(os.path.exists(path))


class SnapshotDiskGuardTests(unittest.TestCase):
    def _with_free(self, free_bytes):
        import shutil
        from unittest import mock
        usage = shutil.disk_usage("/")._replace(free=free_bytes)
        return mock.patch("shutil.disk_usage", return_value=usage)

    def test_skips_when_snapshot_would_eat_the_swap_floor(self):
        with self._with_free(4 * 1024 ** 3):
            reason = bridge._snapshot_skip_reason("/tmp/state.json", 1 * 1024 ** 3, "legacy")  # ~3.8 GB to write
        self.assertIsNotNone(reason)
        self.assertIn("skipped", reason)

    def test_writes_when_there_is_room(self):
        with self._with_free(50 * 1024 ** 3):
            self.assertIsNone(bridge._snapshot_skip_reason("/tmp/state.json", 1 * 1024 ** 3, "legacy"))

    def test_tokens_mode_needs_less_room_than_legacy(self):
        with self._with_free(6 * 1024 ** 3):
            self.assertIsNotNone(bridge._snapshot_skip_reason("/tmp/s.json", 1 * 1024 ** 3, "legacy"))
            self.assertIsNone(bridge._snapshot_skip_reason("/tmp/s.json", 1 * 1024 ** 3, "tokens"))


@unittest.skipUnless(HAVE_MLX, "needs mlx + mlx_lm")
class PrefixReuseEquivalenceTests(unittest.TestCase):
    def setUp(self):
        ensure_real_mlx_lm()
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

    def test_skipped_snapshot_is_a_clean_miss(self):
        from unittest import mock
        state = os.path.join(tempfile.mkdtemp(), "state.json")
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
        state = state or os.path.join(tempfile.mkdtemp(), "state.json")
        cache = make_prompt_cache(self.model)
        gen = self._greedy(prompt, cache, n=n)
        bridge._finish_token_prefix("live", state, cache, prompt + gen, {}, cache_key=key)
        return state, prompt + gen

    def test_live_caches_are_isolated_per_session(self):
        state = os.path.join(tempfile.mkdtemp(), "state.json")
        _, a_tokens = self._finish_live("session:A", list(range(10, 40)), state=state)
        _, b_tokens = self._finish_live("session:B", list(range(50, 80)), state=state)
        self.assertEqual(set(bridge._LIVE_PREFIX_CACHES), {"session:A", "session:B"})
        # session B continuing its own conversation hits ITS cache, and A's stays untouched
        _, _, hit, reused = bridge._token_prefix_reuse(
            "live", state, None, b_tokens + [5, 6], make_prompt_cache, self.model, KVCache, cache_key="session:B")
        self.assertTrue(hit)
        self.assertEqual(reused, len(b_tokens))
        self.assertIn("session:A", bridge._LIVE_PREFIX_CACHES)
        self.assertEqual(bridge._LIVE_PREFIX_CACHES["session:A"][0], a_tokens)
        # a NEW session never borrows another session's cache, even with an identical prefix
        _, _, hit, _ = bridge._token_prefix_reuse(
            "live", state, None, a_tokens + [5], make_prompt_cache, self.model, KVCache, cache_key="session:C")
        self.assertFalse(hit)
        self.assertIn("session:A", bridge._LIVE_PREFIX_CACHES)

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
            state = os.path.join(tempfile.mkdtemp(), "state.json")
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
            state = os.path.join(tempfile.mkdtemp(), "state.json")
            for key in ("session:A", "session:B", "session:C"):
                self._finish_live(key, list(range(10, 30)), state=state)
            self.assertEqual(list(bridge._LIVE_PREFIX_CACHES), ["session:B", "session:C"])
        finally:
            del os.environ["ESH_MLX_LIVE_PREFIX_SLOTS"]

    def test_non_trimmable_caches_are_not_retained(self):
        from mlx_lm.models.cache import RotatingKVCache
        state = os.path.join(tempfile.mkdtemp(), "state.json")
        cache = [RotatingKVCache(max_size=8) for _ in self.model.layers]
        prompt = list(range(10, 40))
        gen = self._greedy(prompt, cache, n=4)
        payload = bridge._finish_token_prefix("live", state, cache, prompt + gen, {}, cache_key="session:R")
        self.assertIn("not trimmable", payload.get("liveNotRetained", ""))
        self.assertNotIn("session:R", bridge._LIVE_PREFIX_CACHES)

    def test_session_cache_key(self):
        self.assertEqual(bridge._session_cache_key({"session": {"id": "abc"}, "stateFilePath": "/s"}), "session:abc")
        self.assertEqual(bridge._session_cache_key({"session": {}, "stateFilePath": "/s"}), "state:/s")

    def test_tokens_mode_keeps_exactly_one_sidecar_referenced_by_the_state(self):
        state = os.path.join(tempfile.mkdtemp(), "state.json")
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
        state = os.path.join(tempfile.mkdtemp(), "state.json")
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
