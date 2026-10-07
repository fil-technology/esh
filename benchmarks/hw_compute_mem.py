#!/usr/bin/env python3
"""Phase-B hardware benchmark: compute throughput (CPU numpy + GPU MLX) and memory bandwidth.
Read-only w.r.t. disk; allocates only modest (<=2 GB) buffers to avoid swap on a 32 GB machine with a nearly
full internal volume. Emits JSON on stdout. No sudo, no disk writes."""
import json, time, platform, os
import numpy as np

OUT = {"section": "compute_mem", "host": platform.platform(), "numpy": np.__version__}


def timed(fn, iters=3):
    best = float("inf")
    for _ in range(iters):
        t = time.perf_counter(); fn(); best = min(best, time.perf_counter() - t)
    return best


# ---- CPU memory bandwidth: STREAM-like triad a = b + s*c on float32 ----
def cpu_mem_bw(nbytes=1_500_000_000):
    n = nbytes // 4
    b = np.ones(n, dtype=np.float32); c = np.ones(n, dtype=np.float32) * 2.0
    s = np.float32(3.0)
    def triad(): np.add(b, c * s, out=b)
    t = timed(triad, 5)
    # triad touches 3 arrays (read b, read c, write b) = 3 * n * 4 bytes
    gb = 3 * n * 4 / 1e9
    return {"buffer_bytes": int(n * 4), "triad_best_s": round(t, 4), "triad_GBps": round(gb / t, 1)}


# ---- CPU matmul GFLOPS (numpy / Accelerate) ----
def cpu_matmul(n=4096):
    a = np.random.rand(n, n).astype(np.float32); b = np.random.rand(n, n).astype(np.float32)
    def mm(): np.matmul(a, b)
    t = timed(mm, 3)
    return {"n": n, "best_s": round(t, 4), "GFLOPs": round(2 * n**3 / t / 1e9, 1)}


OUT["cpu_memory_bandwidth"] = cpu_mem_bw()
OUT["cpu_matmul_fp32"] = cpu_matmul()

# ---- GPU (MLX / Metal) ----
try:
    import mlx.core as mx
    OUT["mlx_version"] = getattr(mx, "__version__", "unknown")

    def mlx_matmul(n, dtype):
        a = mx.random.normal((n, n)).astype(dtype); b = mx.random.normal((n, n)).astype(dtype)
        mx.eval(a, b)
        def mm(): mx.eval(a @ b)
        # warmup
        mm()
        t = timed(mm, 5)
        return {"n": n, "dtype": str(dtype).split(".")[-1], "best_s": round(t, 5), "GFLOPs": round(2 * n**3 / t / 1e9, 1)}

    OUT["mlx_matmul_fp32"] = mlx_matmul(4096, mx.float32)
    OUT["mlx_matmul_fp16"] = mlx_matmul(4096, mx.float16)
    OUT["mlx_matmul_bf16"] = mlx_matmul(4096, mx.bfloat16)

    # GPU memory-bandwidth-bound op: large elementwise over ~1.5 GB fp32
    def mlx_mem_bw(nbytes=1_500_000_000):
        n = nbytes // 4
        x = mx.ones((n,), dtype=mx.float32); mx.eval(x)
        def op(): mx.eval(x * 3.0 + 1.0)
        op()
        t = timed(op, 5)
        gb = 2 * n * 4 / 1e9  # read x + write result
        return {"buffer_bytes": int(n * 4), "best_s": round(t, 5), "GBps": round(gb / t, 1)}

    OUT["mlx_memory_bandwidth"] = mlx_mem_bw()

    # Quantized matmul (4-bit) throughput — the format that matters for >RAM models
    try:
        n = 4096
        w = mx.random.normal((n, n)).astype(mx.float16)
        wq, scales, biases = mx.quantize(w, bits=4, group_size=64)
        x = mx.random.normal((1, n)).astype(mx.float16); mx.eval(wq, scales, biases, x)
        def qmm(): mx.eval(mx.quantized_matmul(x, wq, scales, biases, bits=4, group_size=64))
        qmm()
        t = timed(qmm, 20)
        OUT["mlx_quantized_matmul_4bit_vecmat"] = {"n": n, "best_s": round(t, 6), "GFLOPs": round(2 * n * n / t / 1e9, 1)}
    except Exception as e:
        OUT["mlx_quantized_matmul_4bit_vecmat"] = {"error": str(e)}
except Exception as e:
    OUT["mlx_error"] = str(e)

print(json.dumps(OUT, indent=2))
