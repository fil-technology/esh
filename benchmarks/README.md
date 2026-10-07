# esh — Extreme Local Inference benchmarks

Phase-B hardware characterization for the "how far can this Mac push large MoE models" research
(see `docs/research/extreme-local-inference.md`). All numbers in `hardware-profile.json` are **MEASURED**
on the target machine (Apple M1 Pro, 32 GB, external exFAT/USB SSD) on 2026-10-07.

## Scripts

- `hw_compute_mem.py` — CPU memory bandwidth (STREAM triad), CPU matmul (Accelerate), and GPU throughput via
  MLX (fp32/fp16/bf16 matmul, elementwise bandwidth, 4-bit quantized vec-mat). Allocates ≤2 GB; no disk writes.
- `ssd_io_cold.py` — external-SSD **cold** read benchmark. Sequential + random (64 KiB→64 MiB blocks) with
  per-read latency percentiles, plus one-time sequential write. Safe: one bounded test file in a dedicated
  temp dir, deleted in `finally`.

## Run

```bash
~/.esh/runtime/py311/venv/bin/python3 benchmarks/hw_compute_mem.py > /tmp/compute.json
ESH_BENCH_SSD="/Volumes/Sviat SSD" ESH_BENCH_SIZE_GB=40 \
  ~/.esh/runtime/py311/venv/bin/python3 benchmarks/ssd_io_cold.py > /tmp/ssd.json
```

## Cache caveat (important)

macOS `F_NOCACHE` is a **no-op on the exFAT/USB driver**, and `purge` needs sudo. A naive few-GB read test
therefore measures the **unified page cache** (10–80 GB/s) instead of the disk. `ssd_io_cold.py` defeats this
structurally by using a test file **larger than RAM** (`ESH_BENCH_SIZE_GB=40` > 32 GB) and reading the random
battery *first*, so earlier regions are already evicted by the write stream. Sanity check any result: cold reads
must be the same order of magnitude as the fsync'd sequential **write** (~0.87 GB/s here), never tens of GB/s.

## Headline results

| Metric | Measured |
|---|---|
| Unified memory | 32 GB (16 KB pages) |
| Internal free (swap volume) | **9.6 GB** — minimal swap headroom |
| GPU matmul fp16 (MLX) | ~3.7 TFLOP/s |
| Resident 4-bit weight read (decode) | ~39 GB/s effective |
| External SSD sequential read (cold) | ~1.0 GB/s |
| External SSD random read (cold, ≥1 MiB) | ~0.9–1.1 GB/s |
| External SSD random read (64 KiB) | ~0.31 GB/s, 0.25 ms p50 |

**Bottom line:** resident 4-bit weight access (~39 GB/s) is ~40× faster than SSD streaming (~1 GB/s). An
SSD-streamed model is capped at ~`1.0e9 / (bytes read per token)` tok/s. The dominant lever on this machine is
**fitting the model in RAM via mixed quantization**, not streaming experts from the external SSD.
