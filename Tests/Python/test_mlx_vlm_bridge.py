from __future__ import annotations

import importlib.util
import sys
import types
import unittest
from pathlib import Path

import numpy as np


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
BRIDGE_PATH = REPOSITORY_ROOT / "Tools" / "mlx_vlm_bridge.py"


def load_bridge_module():
    triattention_runtime = types.ModuleType("triattention_runtime")
    triattention_runtime.calibrate_model = lambda *args, **kwargs: None
    triattention_runtime.maybe_apply_triattention = lambda *args, **kwargs: None
    sys.modules["triattention_runtime"] = triattention_runtime

    mlx_lm = types.ModuleType("mlx_lm")
    mlx_lm_models = types.ModuleType("mlx_lm.models")
    mlx_lm_cache = types.ModuleType("mlx_lm.models.cache")
    mlx_lm_cache.save_prompt_cache = lambda file_name, cache, metadata: None
    sys.modules["mlx_lm"] = mlx_lm
    sys.modules["mlx_lm.models"] = mlx_lm_models
    sys.modules["mlx_lm.models.cache"] = mlx_lm_cache

    spec = importlib.util.spec_from_file_location("mlx_vlm_bridge_under_test", BRIDGE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FakeBFloat16Array:
    shape = (1, 2)
    dtype = "bfloat16"
    nbytes = 4

    def __array__(self, dtype=None, copy=None):
        raise TypeError("from string B does not match the dtype B item size 1")

    def astype(self, dtype):
        if dtype != "float32":
            raise AssertionError(f"unexpected cast dtype {dtype!r}")
        return np.array([[1.25, -2.5]], dtype=np.float32)


class FakeCache:
    def __init__(self):
        self.state = (FakeBFloat16Array(), FakeBFloat16Array())


class MLXVLMBridgeTests(unittest.TestCase):
    def test_prompt_cache_snapshot_casts_bfloat16_arrays_for_json_fallback(self):
        bridge = load_bridge_module()
        bridge._mlx_dtype = lambda dtype: dtype

        snapshot = bridge._prompt_cache_to_snapshot([FakeCache()], metadata={})

        self.assertEqual(snapshot["metadata"]["raw_bytes"], "16")
        self.assertEqual(snapshot["tensors"][0]["dtype"], "float32")
        self.assertEqual(snapshot["tensors"][1]["dtype"], "float32")


if __name__ == "__main__":
    unittest.main()
