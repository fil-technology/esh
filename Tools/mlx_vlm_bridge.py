#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import inspect
import json
import sys
import tempfile
import time
from typing import Any
from importlib.metadata import version

import numpy as np
from pathlib import Path

from triattention_runtime import calibrate_model, maybe_apply_triattention


MLX_RESUME_OVERLAP_TOKENS = 2
MLX_VLM_PACKAGE_VERSION = "0.5.0"
MLX_MINIMUM_VERSION = "0.31.2"
MLX_LM_MINIMUM_VERSION = "0.31.3"


def _fail(message: str, exit_code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(exit_code)


def _load_json() -> dict[str, Any]:
    try:
        return json.load(sys.stdin)
    except Exception as exc:
        _fail(f"Failed to decode stdin JSON: {exc}")


def _dump_json(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, separators=(",", ":"))


import threading as _threading

_EMIT_LOCK = _threading.Lock()


def _emit_json_line(payload: dict[str, Any]) -> None:
    line = json.dumps(payload, separators=(",", ":")) + "\n"
    # Serialize writes so the persistent worker's reader/generator threads never interleave a line.
    with _EMIT_LOCK:
        sys.stdout.write(line)
        sys.stdout.flush()

def _cache_offset(prompt_cache, fallback: int) -> int:
    """Context-token count from a prompt cache. Newer mlx-lm cache types (e.g. ArraysCache) do not
    expose `.offset`; fall back to the processed prompt length rather than crashing."""
    if not prompt_cache:
        return int(fallback)
    off = getattr(prompt_cache[0], "offset", None)
    return int(off) if off is not None else int(fallback)



def _import_mlx_vlm():
    try:
        import mlx.core as mx
        from mlx_vlm.models.cache import KVCache
        from mlx_vlm.turboquant import TurboQuantKVCache
    except Exception as exc:
        _fail(
            f"mlx-vlm v{MLX_VLM_PACKAGE_VERSION} TurboQuant bridge requires Python packages "
            f"`mlx>={MLX_MINIMUM_VERSION}`, `mlx-lm>={MLX_LM_MINIMUM_VERSION}`, "
            f"and `mlx-vlm=={MLX_VLM_PACKAGE_VERSION}`: "
            f"{exc}"
        )
    return mx, KVCache, TurboQuantKVCache


def _import_mlx_lm():
    try:
        import mlx.core as mx
        from mlx_lm.generate import generate_step, stream_generate
        from mlx_lm.models.cache import KVCache, make_prompt_cache
        from mlx_lm.utils import load
    except Exception as exc:
        _fail(
            "MLX bridge requires Python packages `mlx` and `mlx-lm`: "
            f"{exc}"
        )
    return mx, generate_step, stream_generate, KVCache, make_prompt_cache, load


def _supported_kwargs(function: Any, values: dict[str, Any]) -> dict[str, Any]:
    try:
        signature = inspect.signature(function)
    except (TypeError, ValueError):
        return {}

    parameters = signature.parameters
    if any(parameter.kind == inspect.Parameter.VAR_KEYWORD for parameter in parameters.values()):
        return {key: value for key, value in values.items() if value is not None}
    return {
        key: value
        for key, value in values.items()
        if value is not None and key in parameters
    }


def _temperature_kwarg_name(function: Any) -> str:
    try:
        parameters = inspect.signature(function).parameters
    except (TypeError, ValueError):
        return "temp"
    if "temp" in parameters:
        return "temp"
    if "temperature" in parameters:
        return "temperature"
    return "temp"


def _make_mlx_sampler(config: dict[str, Any]):
    try:
        from mlx_lm.sample_utils import make_sampler
    except Exception:
        return None

    values = {
        "top_p": config.get("topP"),
        "top_k": config.get("topK"),
        "min_p": config.get("minP"),
    }
    values[_temperature_kwarg_name(make_sampler)] = config.get("temperature")
    kwargs = _supported_kwargs(make_sampler, values)
    if not kwargs:
        return None
    return make_sampler(**kwargs)


def _make_mlx_logits_processors(config: dict[str, Any]):
    repetition_penalty = config.get("repetitionPenalty")
    if repetition_penalty is None:
        return None

    try:
        from mlx_lm.sample_utils import make_logits_processors
    except Exception:
        return None

    kwargs = _supported_kwargs(
        make_logits_processors,
        {"repetition_penalty": repetition_penalty},
    )
    if not kwargs:
        return None
    return make_logits_processors(**kwargs)


def _mlx_stream_generation_kwargs(stream_generate: Any, mx: Any, config: dict[str, Any]) -> dict[str, Any]:
    seed = config.get("seed")
    if seed is not None and hasattr(mx, "random") and hasattr(mx.random, "seed"):
        mx.random.seed(int(seed))

    sampler = _make_mlx_sampler(config)
    logits_processors = _make_mlx_logits_processors(config)
    kwargs = _supported_kwargs(
        stream_generate,
        {
            _temperature_kwarg_name(stream_generate): config.get("temperature"),
            "top_p": config.get("topP"),
            "top_k": config.get("topK"),
            "min_p": config.get("minP"),
            "sampler": sampler,
            "logits_processors": logits_processors,
        },
    )
    if "sampler" in kwargs:
        kwargs.pop("temp", None)
        kwargs.pop("temperature", None)
        kwargs.pop("top_p", None)
        kwargs.pop("top_k", None)
        kwargs.pop("min_p", None)
    if "logits_processors" in kwargs and kwargs["logits_processors"] is None:
        kwargs.pop("logits_processors", None)
    return kwargs


def _maybe_apply_turboquant(prompt_cache, bits: float, seed: int):
    from mlx_lm.models.cache import CacheList, KVCache, RotatingKVCache

    _, _, TurboQuantKVCache = _import_mlx_vlm()

    def convert(entry):
        if isinstance(entry, TurboQuantKVCache):
            return entry
        if isinstance(entry, RotatingKVCache):
            return entry
        if isinstance(entry, KVCache):
            return TurboQuantKVCache.from_cache(entry, bits=bits, seed=seed)
        if isinstance(entry, CacheList):
            entry.caches = [convert(child) for child in entry.caches]
            return entry
        if isinstance(entry, list):
            return [convert(child) for child in entry]
        return entry

    for index in range(len(prompt_cache)):
        prompt_cache[index] = convert(prompt_cache[index])


def _generation_config(request: dict[str, Any]) -> dict[str, Any]:
    config = request.get("config")
    return config if isinstance(config, dict) else {}


def _is_fractional_bits(value: float) -> bool:
    return value != int(value)


def _maybe_apply_generation_kv_quantization(prompt_cache, config: dict[str, Any]) -> str | None:
    kv_bits_value = config.get("kvBits")
    if kv_bits_value is None:
        return None

    kv_bits = float(kv_bits_value)
    if kv_bits <= 0:
        _fail("kv_bits must be greater than zero.")

    scheme = str(config.get("kvQuantScheme") or "").lower()
    if not scheme:
        scheme = "turboquant" if _is_fractional_bits(kv_bits) else "uniform"
    if scheme == "turbo":
        scheme = "turboquant"

    if scheme == "turboquant":
        _maybe_apply_turboquant(
            prompt_cache,
            bits=kv_bits,
            seed=int(config.get("turboSeed", 0)),
        )
        return "turboquant"

    if scheme == "uniform":
        if _is_fractional_bits(kv_bits):
            _fail("Uniform KV cache quantization requires integer kv_bits.")
        try:
            from mlx_lm.generate import maybe_quantize_kv_cache
        except Exception as exc:
            _fail(f"mlx-lm does not expose KV cache quantization support: {exc}")

        kwargs = _supported_kwargs(
            maybe_quantize_kv_cache,
            {
                "quantized_kv_start": int(config.get("quantizedKVStart", 0)),
                "kv_group_size": int(config.get("kvGroupSize", 64)),
                "kv_bits": int(kv_bits),
            },
        )
        if not kwargs:
            kwargs = {
                "quantized_kv_start": int(config.get("quantizedKVStart", 0)),
                "kv_group_size": int(config.get("kvGroupSize", 64)),
                "kv_bits": int(kv_bits),
            }
        maybe_quantize_kv_cache(prompt_cache, **kwargs)
        return "uniform"

    _fail(f"Unsupported kv_quant_scheme: {scheme}")
    return None


def _resolve_requested_kv_mode(request: dict[str, Any]) -> str:
    requested = request.get("kvMode", "raw")
    if requested != "auto":
        return requested

    intent = request.get("sessionIntent", "chat")
    if intent in {"documentqa", "multimodal"}:
        return "turbo"
    if intent in {"code", "agentrun"}:
        return "triattention"
    return "raw"


def _apply_kv_mode(prompt_cache, model, request: dict[str, Any]) -> str:
    effective_mode = _resolve_requested_kv_mode(request)
    requested_mode = request.get("kvMode", "raw")
    triattention_calib = request.get("triattentionCalibPath")
    turbo_bits = float(request.get("turboBits", 3.5))
    turbo_seed = int(request.get("turboSeed", 0))
    generation_kv_mode = _maybe_apply_generation_kv_quantization(prompt_cache, _generation_config(request))
    if generation_kv_mode is not None:
        return generation_kv_mode

    if effective_mode == "triattention":
        try:
            if not triattention_calib or not Path(triattention_calib).exists():
                raise FileNotFoundError("TriAttention calibration file not found.")
            maybe_apply_triattention(
                prompt_cache,
                model,
                triattention_calib,
                budget=int(request.get("triattentionBudget", 2048)),
            )
            return "triattention"
        except Exception:
            if requested_mode != "auto":
                raise
            effective_mode = "turbo"

    if effective_mode == "turbo":
        try:
            _maybe_apply_turboquant(prompt_cache, bits=turbo_bits, seed=turbo_seed)
            return "turbo"
        except Exception:
            if requested_mode != "auto":
                raise
            return "raw"

    return "raw"


def _numpy_dtype(dtype: str):
    normalized = dtype.split(".")[-1].lower()
    mapping = {
        "float16": np.float16,
        "float32": np.float32,
        "uint32": np.uint32,
        "int32": np.int32,
        "uint8": np.uint8,
        "bool_": np.bool_,
    }
    if normalized not in mapping:
        _fail(f"Unsupported tensor dtype: {dtype}")
    return mapping[normalized]


def _normalized_dtype_name(dtype: Any) -> str:
    return str(dtype).split(".")[-1].lower()


def _mlx_dtype(dtype: str):
    import mlx.core as mx

    return getattr(mx, dtype)


def _snapshot_numpy_array(value: Any) -> np.ndarray:
    dtype_name = _normalized_dtype_name(getattr(value, "dtype", ""))
    if dtype_name == "bfloat16" and hasattr(value, "astype"):
        return np.asarray(value.astype(_mlx_dtype("float32")))
    return np.asarray(value)


def _decode_tensor(tensor: dict[str, Any]) -> np.ndarray:
    raw = base64.b64decode(tensor["data"])
    dtype = _numpy_dtype(tensor["dtype"])
    return np.frombuffer(raw, dtype=dtype).reshape(tensor["shape"])


def _encode_tensor(name: str, array: np.ndarray, dtype: str | None = None) -> dict[str, Any]:
    arr = np.asarray(array)
    actual_dtype = dtype or str(arr.dtype)
    return {
        "name": name,
        "shape": list(arr.shape),
        "dtype": actual_dtype,
        "data": base64.b64encode(arr.tobytes()).decode("ascii"),
    }


def _group_kv_tensors(snapshot: dict[str, Any]) -> list[tuple[str, dict[str, Any], dict[str, Any]]]:
    groups: dict[str, dict[str, dict[str, Any]]] = {}
    for tensor in snapshot.get("tensors", []):
        name = tensor["name"]
        if name.endswith(".keys"):
            groups.setdefault(name[:-5], {})["keys"] = tensor
        elif name.endswith(".values"):
            groups.setdefault(name[:-7], {})["values"] = tensor

    pairs = []
    for prefix, pair in sorted(groups.items()):
        if "keys" not in pair or "values" not in pair:
            _fail(f"Incomplete KV tensor pair for prefix {prefix}")
        pairs.append((prefix, pair["keys"], pair["values"]))
    return pairs


def _infer_tensor_shape_from_quantized_state(state: Any) -> list[int] | None:
    if hasattr(state, "norms") and hasattr(state, "qjl_signs"):
        batch, heads, tokens = map(int, state.norms.shape)
        dim = int(state.qjl_signs.shape[-1]) * 32
        return [batch, heads, tokens, dim]
    if hasattr(state, "norms") and hasattr(state, "indices"):
        batch, heads, tokens = map(int, state.norms.shape)
        packed_width = int(state.indices.shape[-1])
        dim = packed_width * 32
        return [batch, heads, tokens, dim]
    return None


def _restore_turboquant_codecs(mx, cache: Any, layer: dict[str, Any], keys_state: Any, values_state: Any) -> None:
    keys_shape = layer.get("keys_shape") or _infer_tensor_shape_from_quantized_state(keys_state)
    values_shape = (
        layer.get("values_shape")
        or keys_shape
        or _infer_tensor_shape_from_quantized_state(values_state)
    )
    if keys_shape is None or values_shape is None:
        _fail("TurboQuant artifact is missing tensor shapes required to rebuild codecs.")
    dummy_keys = mx.zeros(keys_shape, dtype=mx.float32)
    dummy_values = mx.zeros(values_shape, dtype=mx.float32)
    cache._ensure_codecs(dummy_keys, dummy_values)


def _snapshot_to_prompt_cache(snapshot: dict[str, Any], kv_cache_type):
    prompt_cache_blob = snapshot.get("metadata", {}).get("mlx_prompt_cache_safetensors_base64")
    if prompt_cache_blob:
        from mlx_lm.models.cache import load_prompt_cache

        with tempfile.TemporaryDirectory() as temporary_directory:
            cache_file = f"{temporary_directory}/prompt-cache.safetensors"
            with open(cache_file, "wb") as handle:
                handle.write(base64.b64decode(prompt_cache_blob))
            return load_prompt_cache(cache_file)

    prompt_cache = []
    for _, key_tensor, value_tensor in _group_kv_tensors(snapshot):
        cache = kv_cache_type()
        cache.state = (
            _mx_array_from_tensor(key_tensor),
            _mx_array_from_tensor(value_tensor),
        )
        prompt_cache.append(cache)
    return prompt_cache


def _mx_array_from_tensor(tensor: dict[str, Any]):
    import mlx.core as mx

    return mx.array(_decode_tensor(tensor))


def _prompt_cache_to_snapshot(prompt_cache, metadata: dict[str, Any]) -> dict[str, Any]:
    from mlx_lm.models.cache import save_prompt_cache

    tensors = []
    total_bytes = 0
    can_save_prompt_cache = True
    for index, cache in enumerate(prompt_cache):
        keys = None
        values = None
        if hasattr(cache, "state"):
            state = cache.state
            if isinstance(state, tuple) and len(state) == 2:
                keys, values = state
        if (keys is None or values is None) and hasattr(cache, "dequantize"):
            keys, values = cache.dequantize()
            can_save_prompt_cache = False
        if keys is None or values is None:
            can_save_prompt_cache = False
            continue
        if type(cache).__name__ not in {"KVCache", "RotatingKVCache", "ArraysCache", "BatchKVCache", "BatchRotatingKVCache"}:
            can_save_prompt_cache = False
        key_array = _snapshot_numpy_array(keys)
        value_array = _snapshot_numpy_array(values)
        total_bytes += int(key_array.nbytes + value_array.nbytes)
        prefix = f"layer{index}"
        tensors.append(_encode_tensor(f"{prefix}.keys", key_array))
        tensors.append(_encode_tensor(f"{prefix}.values", value_array))

    metadata = {str(k): str(v) for k, v in metadata.items()}
    metadata["raw_bytes"] = str(total_bytes)
    if can_save_prompt_cache:
        with tempfile.TemporaryDirectory() as temporary_directory:
            cache_file = f"{temporary_directory}/prompt-cache.safetensors"
            try:
                save_prompt_cache(cache_file, prompt_cache, metadata)
                with open(cache_file, "rb") as handle:
                    metadata["mlx_prompt_cache_safetensors_base64"] = base64.b64encode(handle.read()).decode("ascii")
            except Exception as exc:
                metadata["mlx_prompt_cache_safetensors_error"] = str(exc)
    return {
        "format": "mlx-cache-snapshot-v1",
        "metadata": metadata,
        "tensors": tensors,
    }


def _render_prompt(
    tokenizer,
    messages: list[dict[str, str]],
    add_generation_prompt: bool,
    config: dict[str, Any] | None = None,
) -> str:
    if getattr(tokenizer, "chat_template", None):
        config = config or {}
        template_kwargs = _supported_kwargs(
            tokenizer.apply_chat_template,
            {
                "enable_thinking": config.get("enableThinking"),
                "thinking_budget": config.get("thinkingBudget"),
                "thinking_start_token": config.get("thinkingStartToken"),
                "thinking_end_token": config.get("thinkingEndToken"),
            },
        )
        return tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=add_generation_prompt,
            **template_kwargs,
        )

    rendered = []
    for message in messages:
        rendered.append(f"{message['role']}: {message['content']}")
    if add_generation_prompt:
        rendered.append("assistant:")
    return "\n".join(rendered)


def _normalize_prompt_text(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = "\n".join(line.rstrip(" \t") for line in text.split("\n"))
    return text.strip()


def _normalize_messages_for_prompt(messages: list[dict[str, str]]) -> list[dict[str, str]]:
    normalized: list[dict[str, str]] = []
    for message in messages:
        content = _normalize_prompt_text(message["content"])
        if not content:
            continue
        normalized.append({"role": message["role"], "content": content})
    return normalized


def _tokenize_prompt(tokenizer, prompt: str) -> list[int]:
    add_special_tokens = getattr(tokenizer, "bos_token", None) is None or not prompt.startswith(
        tokenizer.bos_token
    )
    return tokenizer.encode(prompt, add_special_tokens=add_special_tokens)


def _load_state_file(state_file_path: str) -> dict[str, Any] | None:
    try:
        with open(state_file_path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return None


def _save_state_file(state_file_path: str, payload: dict[str, Any]) -> None:
    with open(state_file_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"))


def _adapter_config_path(model_path: str | Path) -> Path:
    return Path(model_path) / "adapter_config.json"


def _model_config_path(model_path: str | Path) -> Path:
    return Path(model_path) / "config.json"


def _load_adapter_config(model_path: str | Path) -> dict[str, Any]:
    adapter_config_path = _adapter_config_path(model_path)
    with open(adapter_config_path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _adapter_weight_files(model_path: str | Path) -> list[Path]:
    return sorted(Path(model_path).glob("adapter_model*.safetensors"))


def _model_weight_files(model_path: str | Path) -> list[Path]:
    return sorted(Path(model_path).glob("model*.safetensors"))


def _adapter_base_model_id(model_path: str | Path) -> str:
    config = _load_adapter_config(model_path)
    base_model_id = config.get("base_model_name_or_path")
    if not isinstance(base_model_id, str) or not base_model_id.strip():
        raise ValueError("adapter_config.json is missing base_model_name_or_path")
    return base_model_id.strip()


def _is_adapter_only_model_path(model_path: str | Path) -> bool:
    path = Path(model_path)
    return (
        not _model_config_path(path).exists()
        and _adapter_config_path(path).exists()
        and bool(_adapter_weight_files(path))
    )


def _load_mlx_model(load, model_path: str):
    if _is_adapter_only_model_path(model_path):
        model, tokenizer = load(_adapter_base_model_id(model_path), adapter_path=str(model_path))
        try:
            from mlx_lm.utils import load_tokenizer

            tokenizer = load_tokenizer(Path(model_path))
        except Exception:
            pass
        return model, tokenizer
    return load(model_path)


def _config_from_adapter_mapping(adapter_config: dict[str, Any]) -> dict[str, Any] | None:
    auto_mapping = adapter_config.get("auto_mapping")
    if not isinstance(auto_mapping, dict):
        return None
    base_model_class = str(auto_mapping.get("base_model_class", "")).lower()
    mappings = {
        "qwen3_5": "qwen3_5",
        "qwen3": "qwen3",
        "qwen2": "qwen2",
        "qwen": "qwen",
        "llama": "llama",
        "mistral": "mistral",
        "gemma": "gemma",
        "phi": "phi",
    }
    for needle, model_type in mappings.items():
        if needle in base_model_class:
            return {"model_type": model_type}
    return None


def _load_base_model_config(base_model_id: str) -> dict[str, Any]:
    base_path = Path(base_model_id)
    if base_path.exists():
        config_path = base_path / "config.json"
    else:
        from huggingface_hub import hf_hub_download

        config_path = Path(hf_hub_download(base_model_id, filename="config.json"))

    with open(config_path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _validate_mlx_model_path(
    model_path: str,
    config_loader=None,
    get_classes=None,
) -> tuple[bool, str | None]:
    try:
        if get_classes is None:
            from mlx_lm.utils import _get_classes
            get_classes = _get_classes
        config_loader = config_loader or _load_base_model_config
        path = Path(model_path)
        if not path.exists():
            return False, f"Model install path does not exist: {model_path}"

        if _is_adapter_only_model_path(path):
            adapter_config = _load_adapter_config(path)
            inferred_config = _config_from_adapter_mapping(adapter_config)
            if inferred_config is not None:
                config = inferred_config
            else:
                config = config_loader(_adapter_base_model_id(path))
            get_classes(config)
            return True, None

        config_path = _model_config_path(path)
        if not config_path.exists():
            return (
                False,
                "Missing config.json. LoRA/PEFT adapter installs need adapter_config.json and adapter_model.safetensors.",
            )
        if not _model_weight_files(path):
            return False, f"No model*.safetensors files found in {model_path}"

        with open(config_path, "r", encoding="utf-8") as handle:
            config = json.load(handle)
        get_classes(config)
        return True, None
    except Exception as exc:
        return False, str(exc)


def doctor() -> None:
    try:
        import mlx  # noqa: F401
        import mlx_lm  # noqa: F401
        import mlx_vlm  # noqa: F401
        import safetensors  # noqa: F401
    except Exception as exc:
        _fail(f"Bridge environment is not healthy: {exc}")

    _dump_json(
        {
            "pythonExecutable": sys.executable,
            "mlxVersion": version("mlx"),
            "mlxLMVersion": version("mlx-lm"),
            "mlxVLMVersion": version("mlx-vlm"),
            "numpyVersion": version("numpy"),
            "safetensorsVersion": version("safetensors"),
        }
    )


# Chat-template turn/EOS special tokens. When a model emits one of these as text, its
# assistant turn is over. mlx-lm does not reliably treat all of them as stop tokens for
# every model (notably Qwen's <|im_end|>/<|im_start|>), so without this the model runs
# away emitting them as text and hallucinating a multi-turn transcript. We stop at the
# first one and never surface it. These are special tokens that never occur in
# legitimate assistant content (unlike a plain "User:"), so matching them is safe.
# NB: reasoning tags (<think>/</think>) are deliberately NOT here — esh parses them.
_MLX_STOP_MARKERS: tuple[str, ...] = (
    "<|im_start|>", "<|im_end|>", "<|endoftext|>", "<|eot_id|>", "<|eom_id|>",
    "<|end|>", "<|start_header_id|>", "<|end_header_id|>", "<end_of_turn>",
    "<|user|>", "<|assistant|>", "<|system|>", "<｜end▁of▁sentence｜>",
)
_MLX_MAX_STOP_MARKER_LEN = max(len(marker) for marker in _MLX_STOP_MARKERS)


def _find_earliest_stop_marker(text: str) -> int | None:
    """Index of the earliest chat/EOS special token in `text`, or None."""
    earliest: int | None = None
    for marker in _MLX_STOP_MARKERS:
        index = text.find(marker)
        if index != -1 and (earliest is None or index < earliest):
            earliest = index
    return earliest


def _generate_with_loaded_model(
    mx,
    stream_generate,
    KVCache,
    make_prompt_cache,
    model,
    tokenizer,
    request,
    on_token,
    should_cancel=None,
) -> dict:
    """Run one generation against an ALREADY-LOADED model/tokenizer.

    Shared by the one-shot path (`mlx_generate`) and the persistent worker (`mlx_serve`) so both
    behave identically. `on_token(text)` is called per token; `should_cancel()` (optional) is polled
    each step so the persistent worker can interrupt. Returns {"text", "metrics", "kvMode"} instead of
    emitting a done event, leaving event framing to the caller.
    """
    messages = [
        {"role": message["role"], "content": message["text"]}
        for message in request["session"]["messages"]
    ]
    messages = _normalize_messages_for_prompt(messages)
    config = _generation_config(request)
    full_prompt = _render_prompt(
        tokenizer,
        messages,
        add_generation_prompt=True,
        config=config,
    )
    full_prompt_tokens = _tokenize_prompt(tokenizer, full_prompt)
    state_payload = _load_state_file(request["stateFilePath"])

    previous_prompt = ""
    previous_prompt_tokens: list[int] = []
    if state_payload is not None:
        previous_prompt = state_payload.get("rendered_prompt", "")
        if previous_prompt:
            previous_prompt_tokens = _tokenize_prompt(tokenizer, previous_prompt)
    resume_overlap_tokens = int(
        state_payload.get("snapshot", {}).get("metadata", {}).get("resume_overlap_tokens", MLX_RESUME_OVERLAP_TOKENS)
    ) if state_payload is not None else MLX_RESUME_OVERLAP_TOKENS

    cache_hit = False
    cached_tokens = 0
    if (
        state_payload is not None
        and full_prompt.startswith(previous_prompt)
        and full_prompt_tokens[: len(previous_prompt_tokens)] == previous_prompt_tokens
    ):
        replay_start = max(len(previous_prompt_tokens) - resume_overlap_tokens, 0)
        prompt_tokens = full_prompt_tokens[replay_start:]
        prompt_cache = _snapshot_to_prompt_cache(state_payload["snapshot"], KVCache)
        cache_hit = True
        cached_tokens = replay_start  # prefix tokens reused from cache, not reprocessed
    else:
        prompt_tokens = full_prompt_tokens
        prompt_cache = make_prompt_cache(model)

    effective_kv_mode = _apply_kv_mode(prompt_cache, model, request)

    prompt_token_count = len(prompt_tokens)
    reply_parts = []
    last_response = None
    cancelled = False
    stop_hit = False
    pending = ""  # buffered tail that could be the start of a split stop marker

    for response in stream_generate(
        model=model,
        tokenizer=tokenizer,
        prompt=prompt_tokens,
        max_tokens=config["maxTokens"],
        prompt_cache=prompt_cache,
        **_mlx_stream_generation_kwargs(stream_generate, mx, config),
    ):
        last_response = response
        if response.text:
            pending += response.text
            # Stop at the model's turn/EOS special token so it can't run away into a
            # hallucinated transcript, and never surface the marker itself.
            cut = _find_earliest_stop_marker(pending)
            if cut is not None:
                clean = pending[:cut]
                if clean:
                    reply_parts.append(clean)
                    on_token(clean)
                pending = ""
                stop_hit = True
                break
            # Emit everything except a possible partial trailing marker (so a marker
            # split across streamed chunks is still detected once complete).
            safe = len(pending) - _MLX_MAX_STOP_MARKER_LEN + 1
            if safe > 0:
                chunk = pending[:safe]
                pending = pending[safe:]
                reply_parts.append(chunk)
                on_token(chunk)
        if should_cancel is not None and should_cancel():
            cancelled = True
            break
        if response.finish_reason is not None:
            break

    # No stop marker in the buffered tail → it is clean content; flush it.
    if not stop_hit and pending:
        reply_parts.append(pending)
        on_token(pending)

    reply = "".join(reply_parts)
    updated_messages = messages + [{"role": "assistant", "content": reply}]
    rendered_with_reply = _render_prompt(
        tokenizer, updated_messages, add_generation_prompt=False, config=config
    )
    snapshot = _prompt_cache_to_snapshot(
        prompt_cache,
        metadata={
            "rendered_prompt": rendered_with_reply,
            "message_count": len(updated_messages),
            "model_id": request["modelID"],
            "resume_overlap_tokens": MLX_RESUME_OVERLAP_TOKENS,
            "kv_mode": effective_kv_mode,
        },
    )
    _save_state_file(
        request["stateFilePath"],
        {"snapshot": snapshot, "rendered_prompt": rendered_with_reply},
    )

    metrics = {
        "contextTokens": _cache_offset(prompt_cache, prompt_token_count),
        "ttftMilliseconds": (
            (last_response.prompt_tokens / last_response.prompt_tps) * 1000
            if last_response is not None and last_response.prompt_tps
            else None
        ),
        "tokensPerSecond": (
            last_response.generation_tps if last_response is not None else None
        ),
        "memoryBytes": int(mx.get_peak_memory()),
        "cacheSizeBytes": int(snapshot["metadata"]["raw_bytes"]),
        "compressionRatio": None,
        # Measured token accounting (never fabricated; only what the runtime actually reports).
        "promptTokens": (
            int(last_response.prompt_tokens) if last_response is not None else None
        ),
        "generationTokens": (
            int(last_response.generation_tokens) if last_response is not None else None
        ),
        "finishReason": (
            "cancelled"
            if cancelled
            else (last_response.finish_reason if last_response is not None else None)
        ),
        # Realized prompt-cache state (not the chosen strategy — what actually happened this request).
        "cacheHit": cache_hit,
        "cachedTokens": cached_tokens,
    }
    return {"text": reply, "metrics": metrics, "kvMode": effective_kv_mode}


def mlx_generate() -> None:
    mx, _, stream_generate, KVCache, make_prompt_cache, load = _import_mlx_lm()
    request = _load_json()
    model, tokenizer = _load_mlx_model(load, request["modelPath"])
    result = _generate_with_loaded_model(
        mx,
        stream_generate,
        KVCache,
        make_prompt_cache,
        model,
        tokenizer,
        request,
        on_token=lambda text: _emit_json_line({"event": "token", "text": text}),
    )
    _emit_json_line(
        {"event": "done", "text": result["text"], "metrics": result["metrics"], "kvMode": result["kvMode"]}
    )


def mlx_transcribe() -> None:
    """Speech-to-text via mlx_audio. Reads {audioPath, modelPath, language?} from stdin and returns
    {text}. On-device MLX STT (e.g. parakeet); the model is fetched/cached by mlx_audio."""
    request = _load_json()
    try:
        from mlx_audio.stt.generate import generate_transcription
    except Exception as exc:  # noqa: BLE001
        _fail(f"mlx_audio STT is not available: {exc}")
    import tempfile
    out_base = tempfile.mktemp()
    kwargs = {}
    if request.get("language"):
        kwargs["language"] = request["language"]
    try:
        generate_transcription(
            model=request["modelPath"],
            audio=request["audioPath"],
            output_path=out_base,
            format="txt",
            **kwargs,
        )
    except Exception as exc:  # noqa: BLE001
        _fail(f"transcription failed: {exc}")
    txt_path = out_base + ".txt"
    text = ""
    if Path(txt_path).exists():
        text = Path(txt_path).read_text(encoding="utf-8").strip()
        try:
            Path(txt_path).unlink()
        except OSError:
            pass
    _dump_json({"text": text})


def _extract_vlm_text(result: Any) -> str:
    """mlx-vlm's generate() returns a str across versions, or a (text, usage) tuple, or an object with
    a .text attribute. Normalize to a string."""
    if isinstance(result, str):
        return result
    if isinstance(result, tuple) and result:
        first = result[0]
        return first if isinstance(first, str) else getattr(first, "text", str(first))
    text = getattr(result, "text", None)
    return text if isinstance(text, str) else str(result)


def mlx_vlm_generate() -> None:
    """Vision-language generation (UCMR 2.1). Reads {modelPath, prompt, images:[paths], config?} and
    returns {text}. Loads via mlx_vlm (NOT mlx_lm) so image inputs actually reach the model. stdout is
    redirected to stderr around load/generate so model prints never corrupt the JSON protocol."""
    request = _load_json()
    model_path = request["modelPath"]
    prompt = request.get("prompt", "") or ""
    images = request.get("images", []) or []
    config_in = request.get("config") or {}
    max_tokens = int(config_in.get("maxTokens", request.get("maxTokens", 512)))
    temperature = float(config_in.get("temperature", request.get("temperature", 0.0)))

    try:
        from mlx_vlm import load as vlm_load, generate as vlm_generate
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.utils import load_config
    except Exception as exc:  # noqa: BLE001
        _fail(f"mlx-vlm is not available: {exc}")

    real_stdout = sys.stdout
    sys.stdout = sys.stderr
    try:
        model, processor = vlm_load(model_path)
        config = load_config(model_path)
        formatted = apply_chat_template(processor, config, prompt, num_images=len(images))
        gen_kwargs = {"max_tokens": max_tokens, "verbose": False}
        if temperature > 0:
            gen_kwargs["temperature"] = temperature
        result = vlm_generate(model, processor, formatted, images, **gen_kwargs)
        text = _extract_vlm_text(result)
    except Exception as exc:  # noqa: BLE001
        sys.stdout = real_stdout
        _fail(f"vision generation failed: {type(exc).__name__}: {exc}")
    finally:
        sys.stdout = real_stdout

    # Strip any leaked chat/EOS special tokens defensively (same class as the rc.7 MLX fix).
    cut = _find_earliest_stop_marker(text)
    if cut is not None:
        text = text[:cut]
    _dump_json({"text": text.strip()})


def image_segment() -> None:
    """Background removal / segmentation (UCMR 2.1). Reads {imagePath, outputPath} and writes an RGBA
    PNG with the background removed via rembg (U2Net/ISNet). Returns {outputPath, width, height}. rembg +
    onnxruntime are an optional dependency; a clear error is returned when they are not installed."""
    request = _load_json()
    in_path = request["imagePath"]
    out_path = request["outputPath"]
    try:
        from rembg import remove
        from PIL import Image
    except Exception as exc:  # noqa: BLE001
        _fail(f"rembg is not available (install with: pip install rembg onnxruntime): {exc}")

    real_stdout = sys.stdout
    sys.stdout = sys.stderr
    try:
        image = Image.open(in_path).convert("RGBA")
        output = remove(image)
        output.save(out_path)
        width, height = output.size
    except Exception as exc:  # noqa: BLE001
        sys.stdout = real_stdout
        _fail(f"segmentation failed: {type(exc).__name__}: {exc}")
    finally:
        sys.stdout = real_stdout
    _dump_json({"outputPath": out_path, "width": width, "height": height})


def _available_mem_mb() -> "float | None":
    """Best-effort available RAM in MB via `vm_stat` (zero-dep). None if it can't be read."""
    import re
    import subprocess

    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
    except Exception:  # noqa: BLE001
        return None
    page = 4096
    m = re.search(r"page size of (\d+) bytes", out)
    if m:
        page = int(m.group(1))
    pages = 0
    for label in ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"):
        mm = re.search(rf"{label}:\s+(\d+)", out)
        if mm:
            pages += int(mm.group(1))
    return (pages * page) / 1e6 if pages else None


def _mem_pressure_critical() -> bool:
    """True when the kernel reports critical memory pressure (level 4). Best-effort."""
    import subprocess

    try:
        out = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return int(out) >= 4
    except Exception:  # noqa: BLE001
        return False


def _route_hf_cache(path: "str | None") -> None:
    """Route Hugging Face downloads to `path` (the configured assets root, e.g. an external SSD) instead
    of the default internal ~/.cache/huggingface — so large image models never silently fill internal
    disk (UCMR Stage 3, item 10). No-op when path is falsy."""
    import os

    if not path:
        return
    try:
        os.makedirs(path, exist_ok=True)
        os.environ["HF_HOME"] = path
        os.environ["HF_HUB_CACHE"] = os.path.join(path, "hub")
    except Exception:  # noqa: BLE001
        pass


def audio_diarize() -> None:
    """Speaker diarization (UCMR 2.1, Stage 3) via sherpa-onnx (onnxruntime). Reads {audioPath, segModel,
    embModel, numSpeakers?, clusterThreshold?} and returns {segments:[{start,end,speaker}], speakers:N}.
    sherpa-onnx is an OPTIONAL dependency; a clear error is returned when it (or the models) are absent.
    Honest: this labels anonymous speaker CLUSTERS (speaker_0, speaker_1, …), not real identities."""
    import os

    request = _load_json()
    audio_path = request["audioPath"]
    seg_model = request.get("segModel") or ""
    emb_model = request.get("embModel") or ""
    num_speakers = int(request.get("numSpeakers") or -1)
    threshold = float(request.get("clusterThreshold") or 0.5)
    if not os.path.exists(audio_path):
        _fail(f"audio not found: {audio_path}")
    for label, p in (("segmentation", seg_model), ("embedding", emb_model)):
        if not p or not os.path.exists(p):
            _fail(f"diarization {label} model not found (download the sherpa-onnx models and pass its path): {p}")
    try:
        import sherpa_onnx
        import soundfile as sf
    except Exception as exc:  # noqa: BLE001
        _fail(f"sherpa-onnx is not available (install with: pip install sherpa-onnx soundfile): {exc}")

    try:
        config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
            segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
                pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=seg_model)),
            embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=emb_model),
            clustering=sherpa_onnx.FastClusteringConfig(
                num_clusters=num_speakers if num_speakers > 0 else -1,
                threshold=threshold),
        )
        sd = sherpa_onnx.OfflineSpeakerDiarization(config)
        samples, sample_rate = sf.read(audio_path, dtype="float32", always_2d=True)
        mono = samples[:, 0]
        if sample_rate != sd.sample_rate:
            _fail(f"audio sample rate {sample_rate} != model rate {sd.sample_rate}; resample to {sd.sample_rate} Hz first")
        result = sd.process(mono).sort_by_start_time()
        segments = [{"start": round(s.start, 3), "end": round(s.end, 3), "speaker": f"speaker_{s.speaker}"} for s in result]
    except Exception as exc:  # noqa: BLE001
        _fail(f"diarization failed: {type(exc).__name__}: {exc}")
    speakers = len({s["speaker"] for s in segments})
    _dump_json({"segments": segments, "speakers": speakers})


def _run_guarded_image_cli(cmd: list, out_path: str, min_free: float, label: str):
    """Run an mflux CLI as a killable process group while guarding RAM: kill + report on low memory /
    critical pressure instead of thrashing. Returns the output image (width, height). Shared by
    image-generate and image-upscale."""
    import os
    import signal
    import subprocess
    import time

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, start_new_session=True)
    except Exception as exc:  # noqa: BLE001
        _fail(f"{label} failed to launch: {type(exc).__name__}: {exc}")
    _register_child_pgid(proc.pid)   # bridge cancellation reaps this group too (no orphan CLI)

    def _kill() -> None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except Exception:  # noqa: BLE001
            pass
        try:
            proc.wait(timeout=5)
        except Exception:  # noqa: BLE001
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except Exception:  # noqa: BLE001
                pass

    # Kill only when memory is genuinely low: below the hard floor, OR under critical kernel pressure
    # AND still low-ish (< 2x floor). Critical pressure ALONE is normal under heavy load on Apple Silicon
    # (the kernel compresses), so it must not abort a legitimately memory-hungry generation that still has
    # comfortable headroom — that was a false-positive kill.
    while proc.poll() is None:
        time.sleep(1.0)
        avail = _available_mem_mb()
        low = avail is not None and avail < min_free
        pressure_and_low = _mem_pressure_critical() and (avail is None or avail < min_free * 2)
        if low or pressure_and_low:
            _kill()
            detail = f"only {avail:.0f} MB free" if avail is not None else "critical memory pressure"
            _fail(f"{label} stopped to protect the machine: low memory ({detail})")

    _unregister_child_pgid(proc.pid)
    stderr = ""
    try:
        stderr = (proc.stderr.read() if proc.stderr else "") or ""
    except Exception:  # noqa: BLE001
        pass
    if proc.returncode != 0:
        _fail(f"{label} failed (exit {proc.returncode}): {stderr.strip()[-400:]}")
    try:
        from PIL import Image

        with Image.open(out_path) as im:
            return im.size
    except Exception as exc:  # noqa: BLE001
        _fail(f"{label} produced no readable output: {type(exc).__name__}: {exc}")


# Pinned Real-ESRGAN ONNX revision (SceneWorks/real-esrgan-onnx) for reproducible production upscaling.
# Bump deliberately after re-benchmarking; overridable per request via "revision".
REAL_ESRGAN_ONNX_REVISION = "09f741bac80a246b407da3ee902bf5f3291b602f"


def image_upscale_onnx() -> None:
    """Image super-resolution / upscale (UCMR 2.1, Stage 4.1) via Real-ESRGAN ONNX on onnxruntime — the
    default, reproducible, torch-free backend. Reads {imagePath, outputPath, scale?(2|4), modelDir?,
    minFreeMemMB?}. The model (SceneWorks/real-esrgan-onnx, BSD-3, dynamic shape) is downloaded on demand
    into `modelDir` (under the configured assets root, e.g. external SSD) if absent. Runs on the CoreML
    execution provider with a CPU fallback. Returns {outputPath, width, height, scale, provider}."""
    import os

    request = _load_json()
    in_path = request["imagePath"]
    out_path = request["outputPath"]
    scale = int(request.get("scale") or 4)
    if scale not in (2, 4):
        _fail(f"unsupported upscale scale {scale} (Real-ESRGAN ONNX supports 2 or 4)")
    model_dir = request.get("modelDir") or os.path.join(os.path.dirname(sys.executable), "..", "upscale-models")
    min_free = float(request.get("minFreeMemMB") or 1000)
    if not os.path.exists(in_path):
        _fail(f"input image not found: {in_path}")

    avail = _available_mem_mb()
    if avail is not None and avail < min_free:
        _fail(f"image upscale not started: low memory (only {avail:.0f} MB free, need {min_free:.0f} MB)")

    try:
        import numpy as np
        from PIL import Image
        import onnxruntime as ort
    except Exception as exc:  # noqa: BLE001
        _fail(f"onnxruntime/Pillow not available (install with: pip install onnxruntime pillow): {exc}")

    repo = "SceneWorks/real-esrgan-onnx"
    # Pin the revision for reproducibility (production): the model must be identical across machines/time.
    revision = request.get("revision") or REAL_ESRGAN_ONNX_REVISION
    fname = "real_esrgan_x2.onnx" if scale == 2 else "real_esrgan_x4.onnx"
    model_path = os.path.join(model_dir, fname)
    if not os.path.exists(model_path):
        try:
            os.makedirs(model_dir, exist_ok=True)
            from huggingface_hub import hf_hub_download
            got = hf_hub_download(repo_id=repo, filename=fname, revision=revision, local_dir=model_dir)
            model_path = got
        except Exception as exc:  # noqa: BLE001
            _fail(f"could not obtain Real-ESRGAN model {fname} from {repo}@{revision}: {type(exc).__name__}: {exc}")

    # Large-image safety: Real-ESRGAN is fully convolutional, so tile inputs above a threshold with a small
    # overlap and stitch — bounds peak memory instead of running one giant tensor (which OOMs on big inputs).
    # `tile` is the input-space tile size; 0 disables tiling (used for small images). Size-aware memory check
    # uses the ACTUAL output pixels, not just a static floor.
    tile = int(request.get("tile") or 512)
    overlap = int(request.get("overlap") or 16)
    try:
        pil = Image.open(in_path)
        has_alpha = pil.mode in ("RGBA", "LA") or (pil.mode == "P" and "transparency" in pil.info)
        alpha = pil.convert("RGBA").split()[3] if has_alpha else None
        img = pil.convert("RGB")
        in_w, in_h = img.size
        # Size-aware guard: ~4 bytes/px float in + out tensors, ×3 channels, ×~3 working copies. Refuse if the
        # UNTILED path would exceed free memory AND tiling is disabled; with tiling, peak is per-tile so it's safe.
        out_px = in_w * in_h * scale * scale
        if avail is not None and tile <= 0:
            need_mb = (in_w * in_h + out_px) * 3 * 4 * 3 / (1024 * 1024)
            if need_mb > avail:
                _fail(f"image too large for untiled upscale: needs ~{need_mb:.0f} MB, only {avail:.0f} MB free (enable tiling)")

        sess = ort.InferenceSession(model_path, providers=["CoreMLExecutionProvider", "CPUExecutionProvider"])
        name = sess.get_inputs()[0].name

        def run_rgb(rgb_arr):
            x = np.transpose(rgb_arr, (2, 0, 1))[None, ...]
            y = sess.run(None, {name: x})[0]
            y = np.clip(y[0], 0.0, 1.0)
            return np.transpose(y, (1, 2, 0))

        arr = np.asarray(img).astype(np.float32) / 255.0
        tiled = tile > 0 and (in_w > tile or in_h > tile)
        if not tiled:
            out = run_rgb(arr)
        else:
            out = np.zeros((in_h * scale, in_w * scale, 3), dtype=np.float32)
            for ty in range(0, in_h, tile):
                for tx in range(0, in_w, tile):
                    x0, y0 = max(tx - overlap, 0), max(ty - overlap, 0)
                    x1, y1 = min(tx + tile + overlap, in_w), min(ty + tile + overlap, in_h)
                    up = run_rgb(arr[y0:y1, x0:x1, :])
                    # Crop the overlap margin (in output space) and place the core tile region.
                    cx0, cy0 = (tx - x0) * scale, (ty - y0) * scale
                    cw, ch = min(tile, in_w - tx) * scale, min(tile, in_h - ty) * scale
                    out[ty * scale:ty * scale + ch, tx * scale:tx * scale + cw, :] = up[cy0:cy0 + ch, cx0:cx0 + cw, :]
        rgb8 = (out * 255.0 + 0.5).astype(np.uint8)
        result = Image.fromarray(rgb8)

        if alpha is not None:
            # Preserve transparency: upscale the alpha channel with high-quality resampling (the SR model is
            # RGB-only) and re-attach, so PNGs with transparency don't come back opaque.
            up_alpha = alpha.resize((in_w * scale, in_h * scale), Image.LANCZOS)
            result = result.convert("RGBA")
            result.putalpha(up_alpha)

        result.save(out_path)
        out_w, out_h = result.size
        provider = sess.get_providers()[0]
    except Exception as exc:  # noqa: BLE001
        _fail(f"image upscale failed: {type(exc).__name__}: {exc}")
    # Peak process RSS (macOS ru_maxrss is bytes) — accurate self-report for benchmark evidence.
    try:
        import resource
        peak_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)
    except Exception:  # noqa: BLE001
        peak_mb = None
    _dump_json({"outputPath": out_path, "width": out_w, "height": out_h, "scale": scale,
                "nativeScale": scale, "effectiveScale": scale, "tiled": bool(tiled),
                "alphaPreserved": alpha is not None, "provider": provider, "peakMemoryMB": peak_mb})


def image_upscale() -> None:
    """Image super-resolution / upscale (UCMR 2.1, Stage 3) via mflux's SeedVR2 diffusion upscaler. Reads
    {imagePath, outputPath, resolution?, model?, quantize?, minFreeMemMB?, vaeTiling?} and writes an
    upscaled PNG. Returns {outputPath, width, height}. mflux is optional; a clear error otherwise. Uses
    VAE tiling by default to keep peak memory bounded, and the same RAM guard as image generation."""
    import os

    request = _load_json()
    in_path = request["imagePath"]
    out_path = request["outputPath"]
    resolution = request.get("resolution")
    model = request.get("model") or "seedvr2-3b"
    quantize = request.get("quantize")
    min_free = float(request.get("minFreeMemMB") or 1500)
    vae_tiling = request.get("vaeTiling", True)
    if not os.path.exists(in_path):
        _fail(f"input image not found: {in_path}")
    _route_hf_cache(request.get("hfCache"))

    avail = _available_mem_mb()
    if avail is not None and avail < min_free:
        _fail(f"image upscale not started: low memory (only {avail:.0f} MB free, need {min_free:.0f} MB)")

    cli = os.path.join(os.path.dirname(sys.executable), "mflux-upscale-seedvr2")
    if not os.path.exists(cli):
        _fail("mflux is not available (install with: pip install mflux)")

    cmd = [cli, "--model", str(model), "--image-path", in_path, "--output", out_path]
    if resolution is not None:
        cmd += ["--resolution", str(int(resolution))]
    if quantize is not None:
        cmd += ["--quantize", str(int(quantize))]
    if vae_tiling:
        cmd += ["--vae-tiling"]

    out_w, out_h = _run_guarded_image_cli(cmd, out_path, min_free, "image upscale")
    _dump_json({"outputPath": out_path, "width": out_w, "height": out_h})


def image_generate() -> None:
    """Text -> image generation (UCMR 2.1, Stage 3). Reads {prompt, outputPath, steps?, seed?, width?,
    height?, quantize?, minFreeMemMB?} and writes a PNG via mflux's Z-Image Turbo CLI (Apache-2.0, ~8
    steps). Returns {outputPath, width, height}. mflux is an optional dependency; a clear error is
    returned when the CLI is not installed. The model is downloaded on first use (to the HF cache).

    RAM safety: refuses to start, and kills the run mid-flight, when available memory drops below
    `minFreeMemMB` (default 1500) or the kernel reports critical memory pressure — reporting that it was
    stopped instead of letting the machine thrash/crash."""
    import os

    request = _load_json()
    prompt = request.get("prompt") or ""
    out_path = request["outputPath"]
    steps = int(request.get("steps") or 8)
    seed = int(request.get("seed") or 0)
    quantize = request.get("quantize")
    width = request.get("width")
    height = request.get("height")
    min_free = float(request.get("minFreeMemMB") or 1500)
    if not prompt.strip():
        _fail("image generation requires a non-empty prompt")
    _route_hf_cache(request.get("hfCache"))

    # Pre-flight RAM check: don't even start if we're already low.
    avail = _available_mem_mb()
    if avail is not None and avail < min_free:
        _fail(f"image generation not started: low memory (only {avail:.0f} MB free, need {min_free:.0f} MB)")

    # The mflux CLI lives next to this interpreter (same venv/bin).
    cli = os.path.join(os.path.dirname(sys.executable), "mflux-generate-z-image-turbo")
    if not os.path.exists(cli):
        _fail("mflux is not available (install with: pip install mflux)")

    # Default to the pre-quantized 4-bit Z-Image-Turbo (~6.5 GB, lower peak memory) rather than the full
    # bf16 default (~12 GB); overridable via request "model".
    model = request.get("model") or "filipstrand/Z-Image-Turbo-mflux-4bit"
    cmd = [cli, "--model", str(model), "--prompt", prompt, "--output", out_path, "--steps", str(steps), "--seed", str(seed)]
    if quantize is not None:
        cmd += ["--quantize", str(int(quantize))]
    if width is not None:
        cmd += ["--width", str(int(width))]
    if height is not None:
        cmd += ["--height", str(int(height))]

    out_w, out_h = _run_guarded_image_cli(cmd, out_path, min_free, "image generation")
    _dump_json({"outputPath": out_path, "width": out_w, "height": out_h})


# Backends for instruction-based image editing (image + instruction -> image), via mflux CLIs already
# installed alongside this interpreter. Default is the Apache-2.0 Qwen-Image-Edit (commercial-safe);
# FLUX.1 Kontext is available but NON-COMMERCIAL (BFL license) so it's opt-in/experimental, never default.
IMAGE_EDIT_BACKENDS = {
    "qwen-edit": {"cli": "mflux-generate-qwen-edit", "model": "qwen-image-edit", "license": "apache-2.0",
                  "steps": 8, "commercial": True, "image_arg": "--image-paths"},
    "kontext":   {"cli": "mflux-generate-kontext", "model": "dev-kontext", "license": "flux-1-dev-non-commercial",
                  "steps": 28, "commercial": False, "image_arg": "--image-path"},
    # FLUX.2 Klein 4B (Apache-2.0, commercial-safe) — the practical fit on 32GB Macs. mflux quantizes the
    # official weights to 4-bit at load (`quantize` below); a distilled/fast model so few steps suffice.
    "flux2-klein": {"cli": "mflux-generate-flux2-edit", "model": "flux2-klein-4b", "license": "apache-2.0",
                    "steps": 6, "commercial": True, "image_arg": "--image-paths", "quantize": 4},
}


def image_edit() -> None:
    """Instruction-based image editing (UCMR 2.1) — image + natural-language instruction -> edited image.
    Reads {imagePath, outputPath, instruction, backend?(qwen-edit|kontext), model?, steps?, seed?, quantize?,
    guidance?, width?, height?, minFreeMemMB?, hfCache?, vaeTiling?}. Runs the mflux edit CLI as a killable,
    RAM-guarded process (VAE tiling on by default to bound peak memory). The model downloads on first use to
    the configured HF cache (assets root / SSD). Returns {outputPath, width, height, backend, model, license,
    commercial, peakMemoryMB}."""
    import os

    request = _load_json()
    in_path = request["imagePath"]
    out_path = request["outputPath"]
    instruction = (request.get("instruction") or request.get("prompt") or "").strip()
    backend = request.get("backend") or "flux2-klein"
    if backend not in IMAGE_EDIT_BACKENDS:
        _fail(f"unknown image-edit backend '{backend}' (supported: {', '.join(IMAGE_EDIT_BACKENDS)})")
    spec = IMAGE_EDIT_BACKENDS[backend]
    if not instruction:
        _fail("image editing requires a non-empty instruction")
    if not os.path.exists(in_path):
        _fail(f"input image not found: {in_path}")
    _route_hf_cache(request.get("hfCache"))

    # Editing loads a ~12B+ diffusion model; on constrained Macs this is near the memory ceiling. Default to a
    # high floor + low-RAM mode so we never thrash the machine (a raw run once contributed to a watchdog panic).
    min_free = float(request.get("minFreeMemMB") or 4000)
    avail = _available_mem_mb()
    if avail is not None and avail < min_free:
        _fail(f"image editing not started: low memory (only {avail:.0f} MB free, need {min_free:.0f} MB)")

    cli = os.path.join(os.path.dirname(sys.executable), spec["cli"])
    if not os.path.exists(cli):
        _fail(f"mflux edit backend '{backend}' not available ({spec['cli']} missing; install with: pip install mflux)")

    model = request.get("model") or spec["model"]
    steps = int(request.get("steps") or spec["steps"])
    seed = int(request.get("seed") or 0)
    cmd = [cli, "--model", str(model), spec["image_arg"], in_path, "--prompt", instruction,
           "--output", out_path, "--steps", str(steps), "--seed", str(seed)]
    # Quantization: request override, else the backend's default (e.g. flux2-klein loads full weights and
    # quantizes to 4-bit at load so it fits a 32GB Mac).
    quant = request.get("quantize", spec.get("quantize"))
    if quant is not None:
        cmd += ["--quantize", str(int(quant))]
    # A third-party / pre-quantized HuggingFace repo needs its base architecture named (mflux --base-model),
    # e.g. `qwen-image` for a custom Qwen-Image-Edit repo. Request override, else the backend default.
    base_model = request.get("baseModel") or spec.get("base_model")
    if base_model:
        cmd += ["--base-model", str(base_model)]
    if request.get("guidance") is not None:
        cmd += ["--guidance", str(float(request["guidance"]))]
    if request.get("width") is not None:
        cmd += ["--width", str(int(request["width"]))]
    if request.get("height") is not None:
        cmd += ["--height", str(int(request["height"]))]
    # Low-RAM mode ON by default for editing (implies VAE tiling); an mlx cache cap bounds peak further.
    if request.get("lowRam", True):
        cmd += ["--low-ram"]
    elif request.get("vaeTiling", True):
        cmd += ["--vae-tiling"]
    if request.get("mlxCacheLimitGB") is not None:
        cmd += ["--mlx-cache-limit-gb", str(int(request["mlxCacheLimitGB"]))]

    # mflux runs as a separate child process group, so peak memory is sampled externally by the benchmark
    # (bridge RSS here would not reflect the child's footprint).
    out_w, out_h = _run_guarded_image_cli(cmd, out_path, min_free, f"image editing ({backend})")
    _dump_json({"outputPath": out_path, "width": out_w, "height": out_h, "backend": backend,
                "model": model, "license": spec["license"], "commercial": spec["commercial"]})


def mlx_serve() -> None:
    """Persistent MLX worker: load the model ONCE, then serve many requests over stdio.

    Protocol (newline-delimited JSON):
      stdin  : first line `{"op":"init","modelPath":...,"modelID":...}`; then
               `{"id","op":"generate","request":{...}}`, `{"id","op":"cancel"}`,
               `{"op":"ping"}`, `{"op":"shutdown"}`.
      stdout : `{"event":"ready","loadMs","memoryBytes","model"}` once loaded;
               per request `{"id","event":"token","text"}` … `{"id","event":"done","metrics","kvMode"}`
               or `{"id","event":"error","message"}`; `{"event":"pong"}`.
    Model weights stay resident for the worker's lifetime → true residency. stdin EOF (parent death)
    ends the loop, so no orphan workers survive esh.
    """
    import queue as _queue

    mx, _, stream_generate, KVCache, make_prompt_cache, load = _import_mlx_lm()

    init_line = sys.stdin.readline()
    if not init_line:
        return
    try:
        init = json.loads(init_line)
    except Exception as exc:  # noqa: BLE001
        _emit_json_line({"event": "error", "message": f"bad init line: {exc}"})
        raise SystemExit(1)

    load_start = time.time()
    try:
        model, tokenizer = _load_mlx_model(load, init["modelPath"])
    except Exception as exc:  # noqa: BLE001
        _emit_json_line({"event": "error", "message": f"model load failed: {exc}"})
        raise SystemExit(1)
    load_ms = (time.time() - load_start) * 1000.0
    _emit_json_line(
        {
            "event": "ready",
            "loadMs": load_ms,
            "memoryBytes": int(mx.get_peak_memory()),
            "model": init.get("modelID"),
        }
    )

    request_queue: "_queue.Queue" = _queue.Queue()
    cancel_lock = _threading.Lock()
    cancel_ids: set = set()
    stop = _threading.Event()

    def _reader() -> None:
        try:
            for raw in sys.stdin:
                line = raw.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except Exception:  # noqa: BLE001
                    continue
                op = msg.get("op")
                if op == "cancel":
                    with cancel_lock:
                        cancel_ids.add(msg.get("id"))
                elif op == "ping":
                    _emit_json_line({"event": "pong"})
                elif op == "shutdown":
                    break
                elif op == "generate":
                    request_queue.put(msg)
        finally:
            # stdin closed (parent died) or explicit shutdown → stop the worker.
            stop.set()
            request_queue.put(None)

    reader_thread = _threading.Thread(target=_reader, daemon=True)
    reader_thread.start()

    while True:
        msg = request_queue.get()
        if msg is None or stop.is_set():
            break
        req_id = msg.get("id")
        request = msg.get("request", {})

        def _should_cancel(_id=req_id) -> bool:
            with cancel_lock:
                return _id in cancel_ids

        try:
            result = _generate_with_loaded_model(
                mx,
                stream_generate,
                KVCache,
                make_prompt_cache,
                model,
                tokenizer,
                request,
                on_token=lambda text, _id=req_id: _emit_json_line(
                    {"id": _id, "event": "token", "text": text}
                ),
                should_cancel=_should_cancel,
            )
            _emit_json_line(
                {
                    "id": req_id,
                    "event": "done",
                    "metrics": result["metrics"],
                    "kvMode": result["kvMode"],
                }
            )
        except Exception as exc:  # noqa: BLE001
            _emit_json_line({"id": req_id, "event": "error", "message": str(exc)})
        finally:
            with cancel_lock:
                cancel_ids.discard(req_id)


def mlx_build_cache() -> None:
    mx, generate_step, _, _, make_prompt_cache, load = _import_mlx_lm()
    request = _load_json()
    model, tokenizer = _load_mlx_model(load, request["modelPath"])
    messages = [
        {"role": message["role"], "content": message["text"]}
        for message in request["session"]["messages"]
    ]
    messages = _normalize_messages_for_prompt(messages)
    rendered_prompt = _render_prompt(
        tokenizer,
        messages,
        add_generation_prompt=False,
        config=_generation_config(request),
    )
    prompt_tokens = _tokenize_prompt(tokenizer, rendered_prompt)
    prompt_cache = make_prompt_cache(model)
    effective_kv_mode = _apply_kv_mode(prompt_cache, model, request)

    start = time.perf_counter()
    for _ in generate_step(
        mx.array(prompt_tokens),
        model,
        max_tokens=0,
        prompt_cache=prompt_cache,
    ):
        pass
    elapsed = max(time.perf_counter() - start, 1e-6)

    snapshot = _prompt_cache_to_snapshot(
        prompt_cache,
        metadata={
            "rendered_prompt": rendered_prompt,
            "message_count": len(messages),
            "model_id": request["modelID"],
            "resume_overlap_tokens": MLX_RESUME_OVERLAP_TOKENS,
            "kv_mode": effective_kv_mode,
        },
    )
    _save_state_file(
        request["stateFilePath"],
        {"snapshot": snapshot, "rendered_prompt": rendered_prompt},
    )
    metrics = {
        "contextTokens": _cache_offset(prompt_cache, len(prompt_tokens)),
        "ttftMilliseconds": elapsed * 1000,
        "tokensPerSecond": len(prompt_tokens) / elapsed if prompt_tokens else None,
        "memoryBytes": int(mx.get_peak_memory()),
        "cacheSizeBytes": int(snapshot["metadata"]["raw_bytes"]),
        "compressionRatio": None,
    }
    _dump_json({"snapshot": snapshot, "metrics": metrics, "kvMode": effective_kv_mode})


def triattention_calibrate() -> None:
    request = _load_json()
    _, _, _, _, _, load = _import_mlx_lm()
    output_path = request["outputPath"]
    calibration_text = request.get("calibrationText")
    calibration_file_path = request.get("calibrationFilePath")
    if calibration_file_path:
        with open(calibration_file_path, "r", encoding="utf-8") as handle:
            calibration_text = handle.read()

    try:
        written_path = calibrate_model(
            load,
            request["modelPath"],
            output_path,
            calibration_text=calibration_text,
            max_tokens=int(request.get("maxTokens", 4096)),
        )
    except Exception as exc:
        _fail(f"TriAttention calibration failed: {exc}")

    _dump_json({"outputPath": written_path})


def mlx_validate_model() -> None:
    request = _load_json()
    ok, reason = _validate_mlx_model_path(request["modelPath"])
    _dump_json({"ok": ok, "reason": reason})


def mlx_validate_config() -> None:
    request = _load_json()
    try:
        import json as _json
        from mlx_lm.utils import _get_classes

        config = _json.loads(request["configJSON"])
        _get_classes(config)
    except Exception as exc:
        _dump_json({"ok": False, "reason": str(exc)})
        return
    _dump_json({"ok": True, "reason": None})


def mlx_export_cache() -> None:
    request = _load_json()
    state_payload = _load_state_file(request["stateFilePath"])
    snapshot = state_payload["snapshot"] if state_payload else {
        "format": "mlx-cache-snapshot-v1",
        "metadata": {"model_id": request["modelID"]},
        "tensors": [],
    }
    metrics = {
        "contextTokens": None,
        "ttftMilliseconds": None,
        "tokensPerSecond": None,
        "memoryBytes": None,
        "cacheSizeBytes": int(snapshot.get("metadata", {}).get("raw_bytes", "0")),
        "compressionRatio": None,
    }
    _dump_json({"snapshot": snapshot, "metrics": metrics})


def mlx_import_cache() -> None:
    request = _load_json()
    snapshot = request["snapshot"]
    rendered_prompt = snapshot.get("metadata", {}).get("rendered_prompt", "")
    _save_state_file(
        request["stateFilePath"],
        {"snapshot": snapshot, "rendered_prompt": rendered_prompt},
    )
    _dump_json(
        {
            "importedLayerCount": len(_group_kv_tensors(snapshot)),
            "metrics": {
                "contextTokens": None,
                "ttftMilliseconds": None,
                "tokensPerSecond": None,
                "memoryBytes": None,
                "cacheSizeBytes": int(snapshot.get("metadata", {}).get("raw_bytes", "0")),
                "compressionRatio": None,
            },
        }
    )


def _serialize_namedtuple(value: Any) -> Any:
    if hasattr(value, "shape") and hasattr(value, "dtype"):
        return {
            "__tensor__": True,
            "shape": list(value.shape),
            "dtype": str(value.dtype),
            "data": base64.b64encode(np.array(value).tobytes()).decode("ascii"),
        }
    if hasattr(value, "_fields"):
        return {
            "__namedtuple__": type(value).__name__,
            "fields": {
                name: _serialize_namedtuple(getattr(value, name))
                for name in value._fields
            },
        }
    if isinstance(value, tuple):
        return {"__tuple__": [_serialize_namedtuple(item) for item in value]}
    if isinstance(value, list):
        return [_serialize_namedtuple(item) for item in value]
    if isinstance(value, dict):
        return {key: _serialize_namedtuple(item) for key, item in value.items()}
    return value


def _serialize_state(value: Any) -> Any:
    return _serialize_namedtuple(value)


def _restore_namedtuple(mx, turboquant_module, value: Any) -> Any:
    if isinstance(value, list):
        return [_restore_namedtuple(mx, turboquant_module, item) for item in value]
    if isinstance(value, dict) and value.get("__tensor__"):
        array = np.frombuffer(
            base64.b64decode(value["data"]),
            dtype=_numpy_dtype(value["dtype"]),
        ).reshape(value["shape"])
        return mx.array(array)
    if isinstance(value, dict) and "__tuple__" in value:
        return tuple(_restore_namedtuple(mx, turboquant_module, item) for item in value["__tuple__"])
    if isinstance(value, dict) and "__namedtuple__" in value:
        type_name = value["__namedtuple__"]
        fields = {
            key: _restore_namedtuple(mx, turboquant_module, item)
            for key, item in value["fields"].items()
        }
        tuple_type = getattr(turboquant_module, type_name, None)
        if tuple_type is None:
            _fail(f"Unsupported TurboQuant state type: {type_name}")
        return tuple_type(**fields)
    if isinstance(value, dict):
        return {key: _restore_namedtuple(mx, turboquant_module, item) for key, item in value.items()}
    return value


def turboquant_compress(bits: float, seed: int) -> None:
    mx, KVCache, TurboQuantKVCache = _import_mlx_vlm()
    snapshot = _load_json()
    layer_payloads = []
    total_raw_bytes = 0
    total_quant_bytes = 0

    for prefix, key_tensor, value_tensor in _group_kv_tensors(snapshot):
        keys = mx.array(_decode_tensor(key_tensor))
        values = mx.array(_decode_tensor(value_tensor))
        cache = KVCache()
        cache.update_and_fetch(keys, values)
        quantized = TurboQuantKVCache.from_cache(cache, bits=bits, seed=seed)
        key_state, value_state = quantized.state

        total_raw_bytes += int(keys.nbytes + values.nbytes)
        total_quant_bytes += int(quantized.nbytes)
        layer_payloads.append(
            {
                "prefix": prefix,
                "meta_state": list(quantized.meta_state),
                "keys_shape": list(keys.shape),
                "values_shape": list(values.shape),
                "keys_state": _serialize_state(key_state),
                "values_state": _serialize_state(value_state),
            }
        )

    payload = {
        "format": "mlx-vlm-turboquant-artifact-v1",
        "metadata": {
            "engine": "mlx-vlm",
            "engine_version": MLX_VLM_PACKAGE_VERSION,
            "bits": str(bits),
            "seed": str(seed),
            "source_format": snapshot.get("format", "unknown"),
            "source_metadata": snapshot.get("metadata", {}),
            "raw_bytes": str(total_raw_bytes),
            "quantized_bytes": str(total_quant_bytes),
        },
        "layers": layer_payloads,
    }
    _dump_json(payload)


def turboquant_decompress(bits: float, seed: int) -> None:
    mx, _, TurboQuantKVCache = _import_mlx_vlm()
    import mlx_vlm.turboquant as turboquant_module

    artifact = _load_json()
    tensors = []
    metadata = dict(artifact.get("metadata", {}).get("source_metadata", {}))
    metadata["restored_from"] = "mlx-vlm-turboquant-artifact-v1"
    metadata["restored_bits"] = str(bits)
    metadata["restored_seed"] = str(seed)

    for layer in artifact.get("layers", []):
        cache = TurboQuantKVCache(bits=bits, seed=seed)
        cache.meta_state = tuple(layer["meta_state"])
        keys_state = _restore_namedtuple(mx, turboquant_module, layer["keys_state"])
        values_state = _restore_namedtuple(mx, turboquant_module, layer["values_state"])
        cache.state = (keys_state, values_state)
        _restore_turboquant_codecs(mx, cache, layer, keys_state, values_state)
        keys, values = cache.dequantize()
        prefix = layer["prefix"]
        tensors.append(_encode_tensor(f"{prefix}.keys", np.array(keys), dtype=str(keys.dtype)))
        tensors.append(_encode_tensor(f"{prefix}.values", np.array(values), dtype=str(values.dtype)))

    _dump_json(
        {
            "format": artifact.get("metadata", {}).get("source_format", "mlx-cache-snapshot-v1"),
            "metadata": metadata,
            "tensors": tensors,
        }
    )


def speech_serve() -> None:
    """Persistent STT worker (M12): load the speech-to-text model ONCE, then transcribe many requests
    over stdio — eliminating the per-call Python+model reload that makes one-shot `mlx-transcribe`
    cost several seconds every call.

    Protocol (newline-delimited JSON):
      stdin  : first line `{"op":"init","modelPath":...,"modelID"?}`; then
               `{"id","op":"transcribe","audioPath":...,"language"?}`, `{"op":"ping"}`, `{"op":"shutdown"}`.
      stdout : `{"event":"ready","loadMs","memoryBytes","model"}` once loaded;
               per request `{"id","event":"result","text","ms"}` or `{"id","event":"error","message"}`;
               `{"event":"pong"}`.
    Model weights stay resident for the worker's lifetime → true residency. stdin EOF (parent death)
    ends the loop, so no orphan workers survive esh.
    """
    # Emit JSON only to the real stdout; model load/generate may print progress, so we redirect
    # stdout→stderr around those calls to keep the newline-JSON protocol clean.
    real_stdout = sys.stdout

    def emit(payload: dict[str, Any]) -> None:
        line = json.dumps(payload, separators=(",", ":")) + "\n"
        real_stdout.write(line)
        real_stdout.flush()

    try:
        import mlx.core as mx
    except Exception as exc:  # noqa: BLE001
        emit({"event": "error", "message": f"mlx not available: {exc}"})
        raise SystemExit(1)
    try:
        from mlx_audio.stt.utils import load_model
    except Exception as exc:  # noqa: BLE001
        emit({"event": "error", "message": f"mlx_audio STT is not available: {exc}"})
        raise SystemExit(1)

    init_line = sys.stdin.readline()
    if not init_line:
        return
    try:
        init = json.loads(init_line)
    except Exception as exc:  # noqa: BLE001
        emit({"event": "error", "message": f"bad init line: {exc}"})
        raise SystemExit(1)

    load_start = time.time()
    sys.stdout = sys.stderr
    try:
        model = load_model(init["modelPath"])
    except Exception as exc:  # noqa: BLE001
        sys.stdout = real_stdout
        emit({"event": "error", "message": f"STT model load failed: {exc}"})
        raise SystemExit(1)
    finally:
        sys.stdout = real_stdout
    try:
        memory_bytes = int(mx.get_peak_memory())
    except Exception:  # noqa: BLE001
        memory_bytes = 0
    emit({"event": "ready", "loadMs": (time.time() - load_start) * 1000.0,
          "memoryBytes": memory_bytes, "model": init.get("modelID")})

    def _extract_text(result: Any) -> str:
        # model.generate returns either an STTOutput (has .text) or an iterable of segment results.
        if hasattr(result, "text"):
            return (result.text or "").strip()
        parts = []
        for segment in result:
            parts.append(getattr(segment, "text", "") or "")
        return "".join(parts).strip()

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        op = msg.get("op")
        if op == "shutdown":
            break
        if op == "ping":
            emit({"event": "pong"})
            continue
        if op != "transcribe":
            continue
        request_id = msg.get("id")
        kwargs: dict[str, Any] = {}
        if msg.get("language"):
            kwargs["language"] = msg["language"]
        start = time.time()
        sys.stdout = sys.stderr
        try:
            result = model.generate(msg["audioPath"], verbose=False, **kwargs)
            text = _extract_text(result)
            sys.stdout = real_stdout
            emit({"id": request_id, "event": "result", "text": text,
                  "ms": (time.time() - start) * 1000.0})
        except Exception as exc:  # noqa: BLE001
            sys.stdout = real_stdout
            emit({"id": request_id, "event": "error", "message": f"transcription failed: {exc}"})
        finally:
            sys.stdout = real_stdout


def main() -> None:
    _install_child_reaper()   # bridge cancellation must reclaim any long-running worker groups (no orphans)
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=[
            "doctor",
            "turboquant-compress",
            "turboquant-decompress",
            "mlx-build-cache",
            "mlx-generate",
            "mlx-serve",
            "mlx-vlm-generate",
            "image-segment",
            "image-generate",
            "image-edit",
            "image-upscale",
            "image-upscale-onnx",
            "audio-generate",
            "music-generate",
            "audio-diarize",
            "mlx-transcribe",
            "speech-serve",
            "mlx-validate-model",
            "mlx-validate-config",
            "mlx-export-cache",
            "mlx-import-cache",
            "triattention-calibrate",
        ],
    )
    parser.add_argument("--bits", type=float, default=3.5)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    if args.command == "doctor":
        doctor()
    elif args.command == "turboquant-compress":
        turboquant_compress(args.bits, args.seed)
    elif args.command == "turboquant-decompress":
        turboquant_decompress(args.bits, args.seed)
    elif args.command == "mlx-generate":
        mlx_generate()
    elif args.command == "mlx-serve":
        mlx_serve()
    elif args.command == "mlx-vlm-generate":
        mlx_vlm_generate()
    elif args.command == "image-segment":
        image_segment()
    elif args.command == "image-generate":
        image_generate()
    elif args.command == "image-edit":
        image_edit()
    elif args.command == "image-upscale":
        image_upscale()
    elif args.command == "image-upscale-onnx":
        image_upscale_onnx()
    elif args.command == "audio-generate":
        audio_or_music_generate(kind="sound")
    elif args.command == "music-generate":
        audio_or_music_generate(kind="music")
    elif args.command == "audio-diarize":
        audio_diarize()
    elif args.command == "mlx-transcribe":
        mlx_transcribe()
    elif args.command == "speech-serve":
        speech_serve()
    elif args.command == "mlx-build-cache":
        mlx_build_cache()
    elif args.command == "mlx-validate-model":
        mlx_validate_model()
    elif args.command == "mlx-validate-config":
        mlx_validate_config()
    elif args.command == "mlx-export-cache":
        mlx_export_cache()
    elif args.command == "triattention-calibrate":
        triattention_calibrate()
    else:
        mlx_import_cache()


# Generative audio: MusicGen (transformers) for music.generate; also serves audio.generate's neural path
# (a music model used for ambience/SFX — recorded honestly in provenance; a dedicated SFX model like AudioGen
# or Stable Audio is the recommended upgrade). Requested duration is honored (never silently shortened).
_MUSICGEN_MODELS = {
    "music": {"repo": "facebook/musicgen-small", "license": "cc-by-nc-4.0", "provider": "musicgen"},
    "sound": {"repo": "facebook/musicgen-small", "license": "cc-by-nc-4.0", "provider": "musicgen-audio"},
}


# --- Orphan-free cancellation: track child process GROUPS so a parent (bridge) death reclaims them. ---
# Long-running workers are spawned with start_new_session=True (own process group) so THIS process can kill
# the whole tree in one syscall. But a NEW session also means the OS will NOT auto-signal them when the bridge
# dies — so if the bridge is itself terminated (Swift ProcessRunner cancels → SIGTERM, then SIGKILL), those
# groups must be reaped explicitly or they orphan mid-compute. We register each group and install a SIGTERM
# handler that SIGKILLs them before exiting. (SIGKILL to the bridge can't be handled — hence ProcessRunner's
# 2s SIGTERM grace, which this handler uses to tear the workers down first.)
_CHILD_PGIDS: "set[int]" = set()


def _register_child_pgid(pid: int) -> None:
    import os
    try:
        _CHILD_PGIDS.add(os.getpgid(pid))
    except Exception:  # noqa: BLE001
        pass


def _unregister_child_pgid(pid: int) -> None:
    import os
    try:
        _CHILD_PGIDS.discard(os.getpgid(pid))
    except Exception:  # noqa: BLE001
        pass


def _install_child_reaper() -> None:
    """On SIGTERM (bridge cancellation), SIGKILL every registered worker group, then exit — no orphans."""
    import os
    import signal

    def _on_term(signum, _frame):  # noqa: ANN001
        for pgid in list(_CHILD_PGIDS):
            try:
                os.killpg(pgid, signal.SIGKILL)
            except Exception:  # noqa: BLE001
                pass
        os._exit(143)  # 128 + SIGTERM

    try:
        signal.signal(signal.SIGTERM, _on_term)
    except Exception:  # noqa: BLE001
        pass


def _isolated_audiogen_python() -> "str | None":
    """Locate the ISOLATED audio-runtime venv (mlx-audiocraft / AudioGen) — env override, then known paths.
    Kept separate from the main esh venv so its deps never destabilize the MLX LLM/VLM runtime."""
    import os
    cand = [os.environ.get("ESH_AUDIOGEN_PYTHON")]
    cand += [
        "/Volumes/Sviat SSD/esh-runtime/audio/audiogen-mlx/venv/bin/python",
        os.path.expanduser("~/.esh/runtime/audio/audiogen-mlx/venv/bin/python"),
    ]
    for c in cand:
        if c and os.path.exists(c):
            return c
    return None


def _clean_worker_stderr(text: str) -> str:
    """Drop noise (HF rate-limit notice, tqdm weight-loading bars, multiprocessing resource_tracker
    leaked-semaphore warnings) so a surfaced error shows the real cause, not the shutdown chatter."""
    keep = []
    for ln in (text or "").splitlines():
        s = ln.strip()
        if not s:
            continue
        low = s.lower()
        if "resource_tracker" in low or "leaked semaphore" in low or "warnings.warn(" in low:
            continue
        if "loading weights" in low or "you are sending unauthenticated" in low:
            continue
        keep.append(s)
    return "\n".join(keep[-4:])


def _run_sfx_worker(py: str, script: str, env: dict, request: dict):
    """One AudioGen worker attempt. Returns (result_dict | None, returncode, cleaned_stderr)."""
    import os, subprocess, signal, json as _json
    try:
        proc = subprocess.Popen([py, script], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
    except Exception as exc:  # noqa: BLE001
        return None, None, f"failed to launch: {type(exc).__name__}: {exc}"
    _register_child_pgid(proc.pid)
    try:
        out, err = proc.communicate(input=_json.dumps(request), timeout=1200)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:  # noqa: BLE001
            pass
        try:
            proc.communicate(timeout=5)
        except Exception:  # noqa: BLE001
            pass
        return None, "timeout", "timed out"
    finally:
        _unregister_child_pgid(proc.pid)
    if proc.returncode == 0:
        for ln in (out or "").strip().splitlines():
            if ln.strip().startswith("{"):
                try:
                    return _json.loads(ln), 0, ""
                except Exception:  # noqa: BLE001
                    pass
    return None, proc.returncode, _clean_worker_stderr(err or out or "")


def _generate_sfx_isolated(request: dict) -> None:
    """audio.generate SFX → run AudioGen inside the isolated venv (Tools/esh_audiogen.py), RAM-floor guarded.
    The audiocraft/multiprocessing stack occasionally tears down uncleanly and the worker dies with a signal
    (SIGKILL / negative returncode) leaving only a 'leaked semaphore' warning — a transient, non-deterministic
    crash. We retry once on such a crash and surface a clear message (not the shutdown chatter) if it persists."""
    import os
    py = _isolated_audiogen_python()
    if not py:
        _fail("the AudioGen SFX runtime is not installed — run scripts/setup-audio-runtime.sh "
              "(installs mlx-audiocraft into an isolated venv on managed storage)")
    min_free = float(request.get("minFreeMemMB") or 6000)   # AudioGen-medium + T5 is memory-heavy
    avail = _available_mem_mb()
    if avail is not None and avail < min_free:
        _fail(f"sound generation not started: low memory (only {avail:.0f} MB free, need {min_free:.0f} MB)")
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "esh_audiogen.py")
    env = dict(os.environ)
    env.update({"PYTHONUTF8": "1", "COPYFILE_DISABLE": "1",
                "OMP_NUM_THREADS": "1", "TOKENIZERS_PARALLELISM": "false"})  # fewer worker semaphores → fewer leaks
    hf = request.get("hfCache")
    if hf:
        env["HF_HOME"] = hf; env["HF_HUB_CACHE"] = os.path.join(hf, "hub")

    last_code, last_err = None, ""
    for attempt in range(2):   # one retry: the crash is transient and usually passes on a fresh worker
        res, code, errtext = _run_sfx_worker(py, script, env, request)
        if res is not None:
            if res.get("error"):
                _fail(res["error"])
            _dump_json(res)
            return
        last_code, last_err = code, errtext
        # Only retry a signal/crash with no useful diagnostic; a real error (non-empty message) fails fast.
        crashed = (isinstance(code, int) and code != 0) or code == "timeout"
        if not (crashed and not last_err):
            break

    if last_code == "timeout":
        _fail("sound generation timed out")
    signal_hint = ""
    if isinstance(last_code, int) and last_code < 0:
        signal_hint = f" (audio model exited on signal {-last_code})"
    elif last_code == 137:
        signal_hint = " (audio model was killed, signal 9)"
    detail = f": {last_err}" if last_err else ""
    _fail(f"sound generation crashed{signal_hint} — this is usually a transient audio-runtime issue; "
          f"please try again{detail}")


def _peak_normalize(arr, ceiling: float = 0.99):
    """Deterministic true-peak limiter: if the signal would clip (peak > ceiling), scale it down by a single
    constant so the loudest sample sits at `ceiling`. Linear gain preserves relative dynamics exactly; safe
    outputs (peak <= ceiling) are returned untouched. Returns (arr, original_peak, normalized?).
    Mirrored in Tools/esh_audiogen.py (the isolated SFX worker) — keep the two in sync."""
    import numpy as np
    peak = float(np.max(np.abs(arr))) if getattr(arr, "size", 0) else 0.0
    if peak > ceiling:
        return arr * (ceiling / peak), peak, True
    return arr, peak, False


def audio_or_music_generate(kind: str) -> None:
    import os
    request = _load_json()
    prompt = (request.get("prompt") or "").strip()
    out_path = request["outputPath"]
    if not prompt:
        _fail("audio generation requires a text prompt")
    # SFX/ambience → the qualified AudioGen model in the isolated runtime (not MusicGen).
    if kind == "sound":
        _route_hf_cache(request.get("hfCache"))
        _generate_sfx_isolated(request)
        return
    seconds = float(request.get("seconds") or 10.0)
    seconds = max(1.0, min(30.0, seconds))            # MusicGen practical single-shot range
    seed = int(request.get("seed") or 0)
    spec = _MUSICGEN_MODELS.get(kind, _MUSICGEN_MODELS["music"])
    model_repo = request.get("model") or spec["repo"]
    _route_hf_cache(request.get("hfCache"))
    # huggingface_hub freezes its cache dir at import time (pulled in transitively before _route_hf_cache
    # runs), so setting HF_HUB_CACHE alone leaks a duplicate copy onto the internal disk. Pass cache_dir
    # explicitly so MusicGen's weights land ONLY in the routed (SSD) cache. No-op when hfCache is unset.
    hf_cache = request.get("hfCache")
    hub_cache = os.path.join(hf_cache, "hub") if hf_cache else None

    min_free = float(request.get("minFreeMemMB") or 2500)
    avail = _available_mem_mb()
    if avail is not None and avail < min_free:
        _fail(f"audio generation not started: low memory (only {avail:.0f} MB free, need {min_free:.0f} MB)")

    try:
        import torch
        from transformers import MusicgenForConditionalGeneration, AutoProcessor
    except Exception as e:  # pragma: no cover
        _fail(f"audio generation backend unavailable (transformers/torch): {e}")

    if seed:
        torch.manual_seed(seed)
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    # For SFX/ambience, steer the music model away from melody toward field-recording textures.
    text = prompt if kind == "music" else f"{prompt}. ambient field recording, environmental sound, no melody, no drums"
    try:
        proc = AutoProcessor.from_pretrained(model_repo, cache_dir=hub_cache)
        model = MusicgenForConditionalGeneration.from_pretrained(model_repo, cache_dir=hub_cache).to(dev)
        revision = getattr(model.config, "_commit_hash", None)   # resolved HF revision (provenance)
        sr = int(model.config.audio_encoder.sampling_rate)
        inp = proc(text=[text], padding=True, return_tensors="pt").to(dev)
        max_new = int(seconds * 50)                    # ~50 audio frames / second
        with torch.no_grad():
            audio = model.generate(**inp, max_new_tokens=max_new, do_sample=True, guidance_scale=3.0)
        wav = audio[0, 0].detach().cpu().numpy()
    except Exception as e:
        _fail(f"audio generation failed: {e}")

    import soundfile as sf
    wav, peak, normalized = _peak_normalize(wav)   # prevent clipping (MusicGen can exceed full scale)
    sf.write(out_path, wav, sr)
    actual = len(wav) / sr
    _dump_json({"outputPath": out_path, "seconds": round(actual, 3), "sampleRate": sr, "channels": 1,
                "provider": spec["provider"], "model": model_repo, "revision": revision, "license": spec["license"],
                "peak": round(peak, 4), "normalized": normalized})


if __name__ == "__main__":
    main()
