from __future__ import annotations

import importlib.util
import json
import sys
import types
import unittest
from pathlib import Path

import numpy as np


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
BRIDGE_PATH = REPOSITORY_ROOT / "Tools" / "mlx_vlm_bridge.py"


def load_bridge_module(save_prompt_cache=None):
    triattention_runtime = types.ModuleType("triattention_runtime")
    triattention_runtime.calibrate_model = lambda *args, **kwargs: None
    triattention_runtime.maybe_apply_triattention = lambda *args, **kwargs: None
    sys.modules["triattention_runtime"] = triattention_runtime

    mlx_lm = types.ModuleType("mlx_lm")
    mlx_lm_models = types.ModuleType("mlx_lm.models")
    mlx_lm_cache = types.ModuleType("mlx_lm.models.cache")
    mlx_lm_cache.save_prompt_cache = save_prompt_cache or (lambda file_name, cache, metadata: None)
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


KVCache = type(
    "KVCache",
    (),
    {"__init__": lambda self: setattr(self, "state", (np.ones((1, 2), dtype=np.float32), np.ones((1, 2), dtype=np.float32)))},
)


class MLXVLMBridgeTests(unittest.TestCase):
    def test_stop_markers_catch_turn_and_eos_special_tokens(self):
        # Regression for the MLX runaway: models like Qwen emit chat/EOS special tokens
        # as text and mlx-lm does not always stop on them, so generation runs away into a
        # hallucinated multi-turn transcript. The bridge must detect these markers so the
        # loop can stop and never surface them.
        bridge = load_bridge_module()
        for marker in ["<|im_start|>", "<|im_end|>", "<|endoftext|>", "<|eot_id|>",
                       "<|start_header_id|>", "<end_of_turn>"]:
            self.assertEqual(bridge._find_earliest_stop_marker("answer" + marker + "more"), 6,
                             f"expected to stop at {marker!r}")

    def test_stop_marker_returns_earliest_and_ignores_reasoning_tags(self):
        bridge = load_bridge_module()
        # Earliest of several markers.
        text = "hi <|im_end|> then <|endoftext|>"
        self.assertEqual(bridge._find_earliest_stop_marker(text), text.index("<|im_end|>"))
        # No marker → None.
        self.assertIsNone(bridge._find_earliest_stop_marker("a normal reply with no markers"))
        # Reasoning tags are NOT stop markers — esh parses <think>…</think>.
        self.assertIsNone(bridge._find_earliest_stop_marker("<think>reasoning</think> answer"))

    def test_speech_serve_persistent_stt_worker_exists(self):
        # M12: the persistent STT worker must exist so the speech model stays resident across
        # requests instead of reloading per call.
        bridge = load_bridge_module()
        self.assertTrue(hasattr(bridge, "speech_serve"))
        src = (REPOSITORY_ROOT / "Tools" / "mlx_vlm_bridge.py").read_text(encoding="utf-8")
        self.assertIn('"speech-serve"', src)               # registered command
        self.assertIn("speech_serve()", src)               # dispatched
        # Loads the STT model ONCE, then serves transcribe requests over stdio.
        self.assertIn("from mlx_audio.stt.utils import load_model", src)
        self.assertIn('"event": "ready"', src)
        self.assertIn("transcribe", src)

    def test_mlx_vlm_generate_image_path_exists(self):
        # UCMR Stage 2: images must actually reach the model. The bridge previously imported mlx_vlm ONLY
        # for KV-cache classes and generated via mlx_lm (text-only). The new op loads via mlx_vlm.
        bridge = load_bridge_module()
        self.assertTrue(hasattr(bridge, "mlx_vlm_generate"))
        self.assertTrue(hasattr(bridge, "_extract_vlm_text"))
        # _extract_vlm_text normalizes str / tuple / object results.
        self.assertEqual(bridge._extract_vlm_text("hi"), "hi")
        self.assertEqual(bridge._extract_vlm_text(("hi", {"usage": 1})), "hi")
        src = (REPOSITORY_ROOT / "Tools" / "mlx_vlm_bridge.py").read_text(encoding="utf-8")
        self.assertIn('"mlx-vlm-generate"', src)                                   # registered command
        self.assertIn("mlx_vlm_generate()", src)                                   # dispatched
        self.assertIn("from mlx_vlm import load as vlm_load, generate as vlm_generate", src)
        self.assertIn("apply_chat_template", src)
        self.assertIn('request.get("images"', src)                                 # consumes image inputs

    def test_bridge_declares_mlx_vlm_0_5_dependency_contract(self):
        bridge = load_bridge_module()
        requirements = (REPOSITORY_ROOT / "Tools" / "python-requirements.txt").read_text(encoding="utf-8")

        self.assertIn("mlx>=0.31.2", requirements)
        self.assertIn("mlx-lm>=0.31.3", requirements)
        self.assertIn("mlx-vlm==0.5.0", requirements)
        self.assertEqual(bridge.MLX_VLM_PACKAGE_VERSION, "0.5.0")

    def test_render_prompt_passes_supported_thinking_flag_to_chat_template(self):
        bridge = load_bridge_module()

        class Tokenizer:
            chat_template = "template"

            def apply_chat_template(self, messages, tokenize, add_generation_prompt, enable_thinking=None):
                self.kwargs = {
                    "messages": messages,
                    "tokenize": tokenize,
                    "add_generation_prompt": add_generation_prompt,
                    "enable_thinking": enable_thinking,
                }
                return "rendered"

        tokenizer = Tokenizer()

        rendered = bridge._render_prompt(
            tokenizer,
            [{"role": "user", "content": "Think."}],
            add_generation_prompt=True,
            config={"enableThinking": True},
        )

        self.assertEqual(rendered, "rendered")
        self.assertIs(tokenizer.kwargs["enable_thinking"], True)

    def test_apply_kv_mode_uses_generation_kv_quantization_controls(self):
        bridge = load_bridge_module()
        calls = []

        def fake_quantize(prompt_cache, config):
            calls.append((prompt_cache, config))
            return "uniform"

        bridge._maybe_apply_generation_kv_quantization = fake_quantize

        effective = bridge._apply_kv_mode(
            ["cache"],
            object(),
            {
                "kvMode": "raw",
                "config": {
                    "kvBits": 8,
                    "kvQuantScheme": "uniform",
                    "kvGroupSize": 32,
                    "quantizedKVStart": 64,
                },
            },
        )

        self.assertEqual(effective, "uniform")
        self.assertEqual(calls, [(["cache"], {"kvBits": 8, "kvQuantScheme": "uniform", "kvGroupSize": 32, "quantizedKVStart": 64})])

    def test_prompt_cache_snapshot_casts_bfloat16_arrays_for_json_fallback(self):
        bridge = load_bridge_module()
        bridge._mlx_dtype = lambda dtype: dtype

        snapshot = bridge._prompt_cache_to_snapshot([FakeCache()], metadata={})

        self.assertEqual(snapshot["metadata"]["raw_bytes"], "16")
        self.assertEqual(snapshot["tensors"][0]["dtype"], "float32")
        self.assertEqual(snapshot["tensors"][1]["dtype"], "float32")

    def test_prompt_cache_snapshot_falls_back_when_safetensors_write_fails(self):
        def fail_save_prompt_cache(file_name, cache, metadata):
            raise RuntimeError("[write] Unable to write 15518720 bytes to file.")

        bridge = load_bridge_module(save_prompt_cache=fail_save_prompt_cache)

        snapshot = bridge._prompt_cache_to_snapshot([KVCache()], metadata={"model_id": "demo"})

        self.assertEqual(snapshot["metadata"]["raw_bytes"], "16")
        self.assertEqual(snapshot["metadata"]["model_id"], "demo")
        self.assertNotIn("mlx_prompt_cache_safetensors_base64", snapshot["metadata"])
        self.assertIn("mlx_prompt_cache_safetensors_error", snapshot["metadata"])
        self.assertEqual([tensor["name"] for tensor in snapshot["tensors"]], ["layer0.keys", "layer0.values"])

    def test_adapter_only_path_loads_base_model_with_adapter(self):
        bridge = load_bridge_module()
        temp_dir = Path(self._testMethodName)
        temp_dir.mkdir(exist_ok=True)
        try:
            (temp_dir / "adapter_config.json").write_text(
                json.dumps({"base_model_name_or_path": "Qwen/Qwen3.5-4B-Base"}),
                encoding="utf-8",
            )
            (temp_dir / "adapter_model.safetensors").write_text("weights", encoding="utf-8")

            calls = []

            def fake_load(path_or_repo, **kwargs):
                calls.append((path_or_repo, kwargs))
                return "model", "tokenizer"

            model, tokenizer = bridge._load_mlx_model(fake_load, str(temp_dir))

            self.assertEqual((model, tokenizer), ("model", "tokenizer"))
            self.assertEqual(calls, [("Qwen/Qwen3.5-4B-Base", {"adapter_path": str(temp_dir)})])
        finally:
            for child in temp_dir.iterdir():
                child.unlink()
            temp_dir.rmdir()

    def test_adapter_validation_uses_base_model_config_without_loading_weights(self):
        bridge = load_bridge_module()
        temp_dir = Path(self._testMethodName)
        temp_dir.mkdir(exist_ok=True)
        try:
            (temp_dir / "adapter_config.json").write_text(
                json.dumps({"base_model_name_or_path": "Qwen/Qwen3.5-4B-Base"}),
                encoding="utf-8",
            )
            (temp_dir / "adapter_model.safetensors").write_text("weights", encoding="utf-8")

            checked_configs = []

            def fake_config_loader(base_model_id):
                self.assertEqual(base_model_id, "Qwen/Qwen3.5-4B-Base")
                return {"model_type": "qwen3_5"}

            def fake_get_classes(config):
                checked_configs.append(config)
                return object, object

            ok, reason = bridge._validate_mlx_model_path(
                str(temp_dir),
                config_loader=fake_config_loader,
                get_classes=fake_get_classes,
            )

            self.assertTrue(ok)
            self.assertIsNone(reason)
            self.assertEqual(checked_configs, [{"model_type": "qwen3_5"}])
        finally:
            for child in temp_dir.iterdir():
                child.unlink()
            temp_dir.rmdir()


if __name__ == "__main__":
    unittest.main()
