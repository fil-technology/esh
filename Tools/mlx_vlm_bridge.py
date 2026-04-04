#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import sys
import tempfile
import time
from typing import Any
from importlib.metadata import version

import numpy as np


MLX_RESUME_OVERLAP_TOKENS = 2


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


def _emit_json_line(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _import_mlx_vlm():
    try:
        import mlx.core as mx
        from mlx_vlm.models.cache import KVCache
        from mlx_vlm.turboquant import TurboQuantKVCache
    except Exception as exc:
        _fail(
            "mlx-vlm v0.4.3 TurboQuant bridge requires Python packages "
            "`mlx` and `mlx-vlm==0.4.3`: "
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
    for index, cache in enumerate(prompt_cache):
        if not hasattr(cache, "state"):
            continue
        state = cache.state
        if not isinstance(state, tuple) or len(state) != 2:
            continue
        keys, values = state
        key_array = np.array(keys)
        value_array = np.array(values)
        total_bytes += int(key_array.nbytes + value_array.nbytes)
        prefix = f"layer{index}"
        tensors.append(_encode_tensor(f"{prefix}.keys", key_array))
        tensors.append(_encode_tensor(f"{prefix}.values", value_array))

    metadata = {str(k): str(v) for k, v in metadata.items()}
    metadata["raw_bytes"] = str(total_bytes)
    with tempfile.TemporaryDirectory() as temporary_directory:
        cache_file = f"{temporary_directory}/prompt-cache.safetensors"
        save_prompt_cache(cache_file, prompt_cache, metadata)
        with open(cache_file, "rb") as handle:
            metadata["mlx_prompt_cache_safetensors_base64"] = base64.b64encode(handle.read()).decode("ascii")
    return {
        "format": "mlx-cache-snapshot-v1",
        "metadata": metadata,
        "tensors": tensors,
    }


def _render_prompt(tokenizer, messages: list[dict[str, str]], add_generation_prompt: bool) -> str:
    if getattr(tokenizer, "chat_template", None):
        return tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=add_generation_prompt,
        )

    rendered = []
    for message in messages:
        rendered.append(f"{message['role']}: {message['content']}")
    if add_generation_prompt:
        rendered.append("assistant:")
    return "\n".join(rendered)


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


def doctor() -> None:
    try:
        import mlx  # noqa: F401
        import mlx_lm  # noqa: F401
        import mlx_vlm  # noqa: F401
    except Exception as exc:
        _fail(f"Bridge environment is not healthy: {exc}")

    _dump_json(
        {
            "pythonExecutable": sys.executable,
            "mlxVersion": version("mlx"),
            "mlxLMVersion": version("mlx-lm"),
            "mlxVLMVersion": version("mlx-vlm"),
            "numpyVersion": version("numpy"),
        }
    )


def mlx_generate() -> None:
    mx, _, stream_generate, KVCache, make_prompt_cache, load = _import_mlx_lm()
    request = _load_json()
    model, tokenizer = load(request["modelPath"])

    messages = [
        {"role": message["role"], "content": message["text"]}
        for message in request["session"]["messages"]
    ]
    full_prompt = _render_prompt(tokenizer, messages, add_generation_prompt=True)
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

    if (
        state_payload is not None
        and full_prompt.startswith(previous_prompt)
        and full_prompt_tokens[: len(previous_prompt_tokens)] == previous_prompt_tokens
    ):
        replay_start = max(len(previous_prompt_tokens) - resume_overlap_tokens, 0)
        prompt_tokens = full_prompt_tokens[replay_start:]
        prompt_cache = _snapshot_to_prompt_cache(state_payload["snapshot"], KVCache)
    else:
        prompt_tokens = full_prompt_tokens
        prompt_cache = make_prompt_cache(model)

    prompt_token_count = len(prompt_tokens)
    reply_parts = []
    last_response = None

    for response in stream_generate(
        model=model,
        tokenizer=tokenizer,
        prompt=prompt_tokens,
        max_tokens=request["config"]["maxTokens"],
        prompt_cache=prompt_cache,
    ):
        last_response = response
        if response.text:
            reply_parts.append(response.text)
            _emit_json_line({"event": "token", "text": response.text})
        if response.finish_reason is not None:
            break

    reply = "".join(reply_parts)
    updated_messages = messages + [{"role": "assistant", "content": reply}]
    rendered_with_reply = _render_prompt(
        tokenizer, updated_messages, add_generation_prompt=False
    )
    snapshot = _prompt_cache_to_snapshot(
        prompt_cache,
        metadata={
            "rendered_prompt": rendered_with_reply,
            "message_count": len(updated_messages),
            "model_id": request["modelID"],
            "resume_overlap_tokens": MLX_RESUME_OVERLAP_TOKENS,
        },
    )
    _save_state_file(
        request["stateFilePath"],
        {"snapshot": snapshot, "rendered_prompt": rendered_with_reply},
    )

    metrics = {
        "contextTokens": int(prompt_cache[0].offset) if prompt_cache else prompt_token_count,
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
    }
    _emit_json_line({"event": "done", "text": reply, "metrics": metrics})


def mlx_build_cache() -> None:
    mx, generate_step, _, _, make_prompt_cache, load = _import_mlx_lm()
    request = _load_json()
    model, tokenizer = load(request["modelPath"])
    messages = [
        {"role": message["role"], "content": message["text"]}
        for message in request["session"]["messages"]
    ]
    rendered_prompt = _render_prompt(tokenizer, messages, add_generation_prompt=False)
    prompt_tokens = _tokenize_prompt(tokenizer, rendered_prompt)
    prompt_cache = make_prompt_cache(model)

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
        },
    )
    _save_state_file(
        request["stateFilePath"],
        {"snapshot": snapshot, "rendered_prompt": rendered_prompt},
    )
    metrics = {
        "contextTokens": int(prompt_cache[0].offset) if prompt_cache else len(prompt_tokens),
        "ttftMilliseconds": elapsed * 1000,
        "tokensPerSecond": len(prompt_tokens) / elapsed if prompt_tokens else None,
        "memoryBytes": int(mx.get_peak_memory()),
        "cacheSizeBytes": int(snapshot["metadata"]["raw_bytes"]),
        "compressionRatio": None,
    }
    _dump_json({"snapshot": snapshot, "metrics": metrics})


def mlx_validate_model() -> None:
    _, _, _, _, _, load = _import_mlx_lm()
    request = _load_json()
    try:
        load(request["modelPath"])
    except Exception as exc:
        _dump_json({"ok": False, "reason": str(exc)})
        return
    _dump_json({"ok": True, "reason": None})


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
            "engine_version": "0.4.3",
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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=[
            "doctor",
            "turboquant-compress",
            "turboquant-decompress",
            "mlx-build-cache",
            "mlx-generate",
            "mlx-validate-model",
            "mlx-validate-config",
            "mlx-export-cache",
            "mlx-import-cache",
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
    elif args.command == "mlx-build-cache":
        mlx_build_cache()
    elif args.command == "mlx-validate-model":
        mlx_validate_model()
    elif args.command == "mlx-validate-config":
        mlx_validate_config()
    elif args.command == "mlx-export-cache":
        mlx_export_cache()
    else:
        mlx_import_cache()


if __name__ == "__main__":
    main()
