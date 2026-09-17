from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import mlx.core as mx
import mlx.nn as nn
from mlx_lm.models.cache import _BaseCache


DEFAULT_BUDGET = 2048
DEFAULT_DIVIDE_LENGTH = 128
DEFAULT_PROTECT_RECENT = 128
DEFAULT_PROTECT_INITIAL = 4
DEFAULT_OFFSETS = mx.array([2**i for i in range(17)], dtype=mx.float32)


@dataclass
class RoPEConfig:
    head_dim: int
    rotated_dims: int
    traditional: bool
    omega: mx.array
    proportional: bool = False


@dataclass
class TriAttentionCalibData:
    q_center_real: Dict[int, mx.array]
    q_center_imag: Dict[int, mx.array]
    q_mean_norm: Dict[int, mx.array]
    n_layers: int
    n_q_heads: int
    n_kv_heads: int


def extract_rope_config(model: nn.Module) -> Optional[RoPEConfig]:
    layers = _find_layers(model)
    if not layers:
        return None

    target_layer = layers[0]
    for layer in layers:
        attn = _find_attention(layer)
        if attn is not None and not getattr(attn, "is_sliding", False):
            target_layer = layer
            break

    attn = _find_attention(target_layer)
    if attn is None:
        return None

    rope = getattr(attn, "rope", None)
    if rope is None:
        return None

    head_dim = _get_head_dim(attn)
    if head_dim is None:
        return None

    if isinstance(rope, nn.RoPE):
        dims = rope.dims
        return RoPEConfig(
            head_dim=head_dim,
            rotated_dims=dims,
            traditional=rope.traditional,
            omega=_compute_omega_standard(dims, rope.base, rope.scale),
        )

    if hasattr(rope, "_freqs") and hasattr(rope, "rotated_dims"):
        return RoPEConfig(
            head_dim=head_dim,
            rotated_dims=rope.rotated_dims,
            traditional=rope.traditional,
            omega=1.0 / rope._freqs,
            proportional=True,
        )

    return None


def extract_model_info(model: nn.Module) -> Optional[Tuple[int, int, int, int, RoPEConfig]]:
    layers = _find_layers(model)
    if not layers:
        return None

    n_layers = len(layers)
    attn = None
    for layer in layers:
        candidate = _find_attention(layer)
        if candidate is not None and not getattr(candidate, "is_sliding", False):
            attn = candidate
            break
    if attn is None:
        attn = _find_attention(layers[0])
    if attn is None:
        return None

    n_q_heads = getattr(attn, "n_heads", None) or getattr(attn, "num_heads", None)
    n_kv_heads = (
        getattr(attn, "n_kv_heads", None)
        or getattr(attn, "num_key_value_heads", None)
        or n_q_heads
    )
    head_dim = _get_head_dim(attn)
    rope_config = extract_rope_config(model)
    if n_q_heads is None or head_dim is None or rope_config is None:
        return None
    return n_layers, n_q_heads, n_kv_heads, head_dim, rope_config


def _decompose_complex(vectors: mx.array, config: RoPEConfig) -> Tuple[mx.array, mx.array]:
    n_freqs = config.rotated_dims // 2
    if config.proportional:
        half = config.head_dim // 2
        rotated_half = config.rotated_dims // 2
        portion = mx.concatenate(
            [vectors[..., :rotated_half], vectors[..., half : half + rotated_half]],
            axis=-1,
        )
        if config.traditional:
            return portion[..., :n_freqs], portion[..., n_freqs:]
        return portion[..., 0::2], portion[..., 1::2]

    if config.traditional:
        return vectors[..., :n_freqs], vectors[..., n_freqs : 2 * n_freqs]
    return vectors[..., 0 : config.rotated_dims : 2], vectors[..., 1 : config.rotated_dims : 2]


def score_keys(
    cached_keys: mx.array,
    current_pos: int,
    calib: TriAttentionCalibData,
    layer_idx: int,
    rope_config: RoPEConfig,
    offsets: mx.array = DEFAULT_OFFSETS,
) -> mx.array:
    batch_size, kv_heads, sequence_length, _ = cached_keys.shape
    k_real, k_imag = _decompose_complex(cached_keys, rope_config)
    k_mag = mx.sqrt(k_real * k_real + k_imag * k_imag + 1e-12)
    k_phase = mx.arctan2(k_imag, k_real)

    q_real = calib.q_center_real[layer_idx]
    q_imag = calib.q_center_imag[layer_idx]
    q_mean_norm = calib.q_mean_norm[layer_idx]
    q_center_mag = mx.sqrt(q_real * q_real + q_imag * q_imag + 1e-12)
    q_center_phase = mx.arctan2(q_imag, q_real)

    grouped_queries = calib.n_q_heads // calib.n_kv_heads
    n_freqs = rope_config.rotated_dims // 2
    q_center_mag = q_center_mag.reshape(kv_heads, grouped_queries, n_freqs)
    q_center_phase = q_center_phase.reshape(kv_heads, grouped_queries, n_freqs)
    q_mean_norm = q_mean_norm.reshape(kv_heads, grouped_queries, n_freqs)

    phi = q_center_phase[None, :, None, :, :] - k_phase[:, :, :, None, :]
    amp = q_center_mag[None, :, None, :, :] * k_mag[:, :, :, None, :]

    omega = rope_config.omega
    times = (current_pos + offsets).astype(mx.float32)
    t_omega = times[:, None] * omega[None, :]
    cos_tw = mx.cos(t_omega)
    sin_tw = mx.sin(t_omega)

    a = amp * mx.cos(phi)
    b = amp * mx.sin(phi)
    flat_shape = (batch_size * kv_heads * sequence_length * grouped_queries, n_freqs)
    s_trig = a.reshape(flat_shape) @ cos_tw.T - b.reshape(flat_shape) @ sin_tw.T
    s_trig = mx.mean(s_trig, axis=-1).reshape(batch_size, kv_heads, sequence_length, grouped_queries)

    norm_weight = q_mean_norm - q_center_mag
    s_norm = mx.sum(
        norm_weight[None, :, None, :, :] * k_mag[:, :, :, None, :],
        axis=-1,
    )
    score = s_trig + s_norm
    if grouped_queries > 1:
        mean_score = mx.mean(score, axis=2, keepdims=True)
        variance = mx.mean((score - mean_score) ** 2, axis=2, keepdims=True)
        normalized = (score - mean_score) / mx.sqrt(variance + 1e-8)
        return mx.max(normalized, axis=-1)
    return score.squeeze(-1)


class TriAttentionKVCache(_BaseCache):
    def __init__(
        self,
        budget: int = DEFAULT_BUDGET,
        calib: Optional[TriAttentionCalibData] = None,
        layer_idx: int = 0,
        rope_config: Optional[RoPEConfig] = None,
        divide_length: int = DEFAULT_DIVIDE_LENGTH,
        protect_recent: int = DEFAULT_PROTECT_RECENT,
        protect_initial: int = DEFAULT_PROTECT_INITIAL,
    ):
        self.budget = budget
        self.calib = calib
        self.layer_idx = layer_idx
        self.rope_config = rope_config
        self.divide_length = divide_length
        self.protect_recent = protect_recent
        self.protect_initial = protect_initial
        self.keys: Optional[mx.array] = None
        self.values: Optional[mx.array] = None
        self.offset = 0
        self._tokens_since_compress = 0
        self._offsets = DEFAULT_OFFSETS

    @classmethod
    def from_cache(
        cls,
        cache: Any,
        budget: int,
        calib: TriAttentionCalibData,
        layer_idx: int,
        rope_config: RoPEConfig,
        **kwargs,
    ) -> "TriAttentionKVCache":
        instance = cls(
            budget=budget,
            calib=calib,
            layer_idx=layer_idx,
            rope_config=rope_config,
            **kwargs,
        )
        keys, values = cache.state
        if keys is not None:
            instance.keys = keys
            instance.values = values
            instance.offset = cache.offset
            instance._tokens_since_compress = cache.offset
        return instance

    @property
    def state(self) -> Tuple[Optional[mx.array], Optional[mx.array]]:
        return self.keys, self.values

    @state.setter
    def state(self, value):
        if value is not None and len(value) == 2:
            self.keys, self.values = value

    @property
    def nbytes(self) -> int:
        total = 0
        if self.keys is not None:
            total += self.keys.nbytes
        if self.values is not None:
            total += self.values.nbytes
        return total

    def update_and_fetch(self, keys: mx.array, values: mx.array) -> Tuple[mx.array, mx.array]:
        if self.keys is None:
            self.keys = keys
            self.values = values
        else:
            self.keys = mx.concatenate([self.keys, keys], axis=2)
            self.values = mx.concatenate([self.values, values], axis=2)

        new_tokens = keys.shape[2]
        self.offset += new_tokens
        self._tokens_since_compress += new_tokens

        if (
            self.keys is not None
            and self.keys.shape[2] > self.budget
            and self._tokens_since_compress >= self.divide_length
            and self.calib is not None
            and self.rope_config is not None
        ):
            self._compress()

        return self.keys, self.values

    def _compress(self) -> None:
        size = self.keys.shape[2]
        if size <= self.budget:
            return

        scores = score_keys(
            self.keys,
            self.offset,
            self.calib,
            self.layer_idx,
            self.rope_config,
            self._offsets,
        )
        avg_scores = mx.mean(scores, axis=1)

        if self.protect_initial > 0:
            avg_scores = mx.concatenate(
                [
                    mx.full((avg_scores.shape[0], self.protect_initial), 1e9, dtype=avg_scores.dtype),
                    avg_scores[:, self.protect_initial :],
                ],
                axis=1,
            )
        if self.protect_recent > 0 and size > self.protect_recent:
            avg_scores = mx.concatenate(
                [
                    avg_scores[:, : -self.protect_recent],
                    mx.full((avg_scores.shape[0], self.protect_recent), 1e9, dtype=avg_scores.dtype),
                ],
                axis=1,
            )

        keep_count = min(self.budget, size)
        keep_index = mx.sort(mx.argpartition(-avg_scores[0], kth=keep_count - 1)[:keep_count])
        self.keys = self.keys[:, :, keep_index, :]
        self.values = self.values[:, :, keep_index, :]
        self._tokens_since_compress = 0
        mx.eval(self.keys, self.values)

    @property
    def meta_state(self):
        return tuple(map(str, (self.budget, self.offset, self._tokens_since_compress)))

    @meta_state.setter
    def meta_state(self, value):
        self.budget, self.offset, self._tokens_since_compress = map(int, value)


def save_calibration(calib: TriAttentionCalibData, path: str) -> None:
    import numpy as np
    from safetensors.numpy import save_file

    data = {}
    for layer_idx in range(calib.n_layers):
        data[f"layer.{layer_idx}.q_center_real"] = np.array(calib.q_center_real[layer_idx].astype(mx.float32))
        data[f"layer.{layer_idx}.q_center_imag"] = np.array(calib.q_center_imag[layer_idx].astype(mx.float32))
        data[f"layer.{layer_idx}.q_mean_norm"] = np.array(calib.q_mean_norm[layer_idx].astype(mx.float32))

    save_file(
        data,
        path,
        metadata={
            "n_layers": str(calib.n_layers),
            "n_q_heads": str(calib.n_q_heads),
            "n_kv_heads": str(calib.n_kv_heads),
        },
    )


def load_calibration(path: str) -> TriAttentionCalibData:
    from safetensors import safe_open

    tensors = {}
    with safe_open(path, framework="numpy") as handle:
        metadata = handle.metadata()
        for key in handle.keys():
            tensors[key] = mx.array(handle.get_tensor(key))

    n_layers = int(metadata["n_layers"])
    q_center_real = {}
    q_center_imag = {}
    q_mean_norm = {}
    for index in range(n_layers):
        q_center_real[index] = tensors[f"layer.{index}.q_center_real"]
        q_center_imag[index] = tensors[f"layer.{index}.q_center_imag"]
        q_mean_norm[index] = tensors[f"layer.{index}.q_mean_norm"]

    return TriAttentionCalibData(
        q_center_real=q_center_real,
        q_center_imag=q_center_imag,
        q_mean_norm=q_mean_norm,
        n_layers=n_layers,
        n_q_heads=int(metadata["n_q_heads"]),
        n_kv_heads=int(metadata["n_kv_heads"]),
    )


def maybe_apply_triattention(
    prompt_cache: List[Any],
    model: nn.Module,
    calib_path: str,
    budget: int = DEFAULT_BUDGET,
    divide_length: int = DEFAULT_DIVIDE_LENGTH,
    protect_recent: int = DEFAULT_PROTECT_RECENT,
    protect_initial: int = DEFAULT_PROTECT_INITIAL,
) -> None:
    from mlx_lm.models.cache import CacheList, KVCache, RotatingKVCache

    calib = load_calibration(calib_path)
    rope_config = extract_rope_config(model)
    if rope_config is None:
        raise ValueError(
            "TriAttention could not extract a supported RoPE configuration for this model."
        )

    def convert(entry: Any, layer_idx: int) -> Any:
        if isinstance(entry, TriAttentionKVCache):
            return entry
        if isinstance(entry, RotatingKVCache):
            return entry
        if isinstance(entry, KVCache):
            if entry.offset == 0:
                return TriAttentionKVCache(
                    budget=budget,
                    calib=calib,
                    layer_idx=layer_idx,
                    rope_config=rope_config,
                    divide_length=divide_length,
                    protect_recent=protect_recent,
                    protect_initial=protect_initial,
                )
            return TriAttentionKVCache.from_cache(
                entry,
                budget=budget,
                calib=calib,
                layer_idx=layer_idx,
                rope_config=rope_config,
                divide_length=divide_length,
                protect_recent=protect_recent,
                protect_initial=protect_initial,
            )
        if isinstance(entry, CacheList):
            entry.caches = [convert(subentry, layer_idx) for subentry in entry.caches]
            return entry
        if isinstance(entry, list):
            return [convert(subentry, layer_idx) for subentry in entry]
        return entry

    for layer_idx in range(len(prompt_cache)):
        prompt_cache[layer_idx] = convert(prompt_cache[layer_idx], layer_idx)


class _CaptureWrapper:
    def __init__(self, wrapped: nn.Module, capture_list: List[mx.array]):
        object.__setattr__(self, "_wrapped", wrapped)
        object.__setattr__(self, "_capture_list", capture_list)

    def __getattr__(self, name: str):
        return getattr(object.__getattribute__(self, "_wrapped"), name)

    def __call__(self, x, mask=None, cache=None, **kwargs):
        wrapped = object.__getattribute__(self, "_wrapped")
        captures = object.__getattribute__(self, "_capture_list")
        batch_size, sequence_length, _ = x.shape
        n_heads = getattr(wrapped, "n_heads", None) or getattr(wrapped, "num_heads", None)
        if n_heads is not None:
            query = wrapped.q_proj(x).reshape(batch_size, sequence_length, n_heads, -1)
            if hasattr(wrapped, "q_norm"):
                query = wrapped.q_norm(query)
            captures.append(mx.stop_gradient(query))
        return wrapped(x, mask=mask, cache=cache, **kwargs)


def calibrate_model(
    load_model,
    model_path: str,
    output_path: str,
    calibration_text: Optional[str] = None,
    max_tokens: int = 4096,
) -> str:
    from mlx_lm.models.cache import make_prompt_cache

    model, tokenizer = load_model(model_path)
    info = extract_model_info(model)
    if info is None:
        raise ValueError("Could not extract model information for TriAttention calibration.")
    n_layers, n_q_heads, n_kv_heads, _, rope_config = info

    text = calibration_text or DEFAULT_CALIBRATION_TEXT
    tokens = tokenizer.encode(text)
    tokens = tokens[:max_tokens]
    input_ids = mx.array([tokens])

    captures: Dict[int, List[mx.array]] = {}
    hooks = _install_capture_hooks(model, captures)
    cache = make_prompt_cache(model)
    try:
        model(input_ids, cache=cache)
        mx.eval()
    finally:
        _remove_hooks(hooks)

    calib = compute_statistics(captures, rope_config, n_q_heads, n_kv_heads, n_layers)
    save_calibration(calib, output_path)
    return output_path


def compute_statistics(
    captures: Dict[int, List[mx.array]],
    rope_config: RoPEConfig,
    n_q_heads: int,
    n_kv_heads: int,
    n_layers: int,
) -> TriAttentionCalibData:
    n_freqs = rope_config.rotated_dims // 2
    q_center_real: Dict[int, mx.array] = {}
    q_center_imag: Dict[int, mx.array] = {}
    q_mean_norm: Dict[int, mx.array] = {}

    for layer_idx in range(n_layers):
        if layer_idx not in captures or not captures[layer_idx]:
            q_center_real[layer_idx] = mx.zeros((n_q_heads, n_freqs))
            q_center_imag[layer_idx] = mx.zeros((n_q_heads, n_freqs))
            q_mean_norm[layer_idx] = mx.zeros((n_q_heads, n_freqs))
            continue

        all_queries = mx.concatenate(captures[layer_idx], axis=1)
        center_real = []
        center_imag = []
        mean_norm = []
        for head_idx in range(n_q_heads):
            head_queries = all_queries[0, :, head_idx, :]
            real, imag = _decompose_complex(head_queries, rope_config)
            center_real.append(mx.mean(real, axis=0))
            center_imag.append(mx.mean(imag, axis=0))
            magnitude = mx.sqrt(real * real + imag * imag + 1e-12)
            mean_norm.append(mx.mean(magnitude, axis=0))

        q_center_real[layer_idx] = mx.stack(center_real)
        q_center_imag[layer_idx] = mx.stack(center_imag)
        q_mean_norm[layer_idx] = mx.stack(mean_norm)
        mx.eval(q_center_real[layer_idx], q_center_imag[layer_idx], q_mean_norm[layer_idx])

    return TriAttentionCalibData(
        q_center_real=q_center_real,
        q_center_imag=q_center_imag,
        q_mean_norm=q_mean_norm,
        n_layers=n_layers,
        n_q_heads=n_q_heads,
        n_kv_heads=n_kv_heads,
    )


def _install_capture_hooks(model: nn.Module, captures: Dict[int, List[mx.array]]) -> List[Any]:
    layers = _find_layers(model)
    if layers is None:
        raise ValueError("Cannot locate transformer layers for TriAttention calibration.")

    hooks = []
    for layer_idx, layer in enumerate(layers):
        attr_name = None
        attn = None
        for candidate in ("self_attn", "attention"):
            if hasattr(layer, candidate):
                attr_name = candidate
                attn = getattr(layer, candidate)
                break
        if attn is None or getattr(attn, "is_sliding", False):
            continue
        captures[layer_idx] = []
        wrapper = _CaptureWrapper(attn, captures[layer_idx])
        setattr(layer, attr_name, wrapper)
        hooks.append((layer, attr_name, attn))
    return hooks


def _remove_hooks(hooks: List[Any]) -> None:
    for layer, attr_name, original in hooks:
        setattr(layer, attr_name, original)


def _find_layers(model: nn.Module) -> Optional[list]:
    if hasattr(model, "model") and hasattr(model.model, "layers"):
        return model.model.layers
    if hasattr(model, "layers"):
        return model.layers
    return None


def _find_attention(layer: nn.Module) -> Optional[nn.Module]:
    return getattr(layer, "self_attn", None) or getattr(layer, "attention", None)


def _get_head_dim(attn: nn.Module) -> Optional[int]:
    head_dim = getattr(attn, "head_dim", None)
    if head_dim is not None:
        return head_dim
    n_heads = getattr(attn, "n_heads", None) or getattr(attn, "num_heads", None)
    if n_heads and hasattr(attn, "q_proj") and hasattr(attn.q_proj, "weight"):
        return attn.q_proj.weight.shape[0] // n_heads
    return None


def _compute_omega_standard(dims: int, base: float, scale: float) -> mx.array:
    exponents = mx.arange(0, dims, 2, dtype=mx.float32) / dims
    return (1.0 / (base**exponents)) / scale


DEFAULT_CALIBRATION_TEXT = (
    "Mathematics studies numbers, shapes, and patterns. "
    "Computer science explores algorithms, data structures, and machine learning. "
    "Physics explains motion, energy, and quantum behavior. "
    "Biology studies DNA, evolution, and ecosystems. "
    "Reasoning, summarization, and code generation all benefit from coherent long-context attention."
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--max-tokens", type=int, default=4096)
    parser.add_argument("--calibration-text", type=str, default=None)
    parser.add_argument("--calibration-file", type=str, default=None)
    args = parser.parse_args()

    from mlx_lm.utils import load

    text = args.calibration_text
    if args.calibration_file is not None:
        text = Path(args.calibration_file).read_text(encoding="utf-8")
    calibrate_model(load, args.model, args.output, calibration_text=text, max_tokens=args.max_tokens)


if __name__ == "__main__":
    main()
