#!/usr/bin/env python3
"""Phase-B external-SSD COLD I/O benchmark (v2). F_NOCACHE is a no-op on the exFAT/USB driver and `purge`
needs sudo, so we defeat the unified page cache structurally: write a test file LARGER than RAM (40 GiB > 32 GB),
which evicts its own earlier pages as it streams, then measure the RANDOM battery FIRST (across the full span,
mostly cold) and finally ONE full sequential pass (file > RAM ⇒ disk-bound). Writes one file, deletes it in
finally. SAFE: bounded size, dedicated dir, cleanup. No sudo. Cross-check: cold reads should be in the same
order of magnitude as the fsync'd sequential WRITE, not 10–80 GB/s (that was cache)."""
import os, json, time, random, shutil, fcntl

SSD = os.environ.get("ESH_BENCH_SSD", "/Volumes/Sviat SSD")
TMPDIR = os.path.join(SSD, "esh-bench-tmp")
PATH = os.path.join(TMPDIR, "iobench.bin")
SIZE = int(os.environ.get("ESH_BENCH_SIZE_GB", "40")) * (1 << 30)   # > 32 GB RAM to defeat cache
F_NOCACHE = 48

OUT = {"section": "ssd_io_cold", "ssd": SSD, "file_bytes": SIZE,
       "method": "file>RAM eviction + F_NOCACHE best-effort; random-first then sequential"}


def _nocache(fd):
    try: fcntl.fcntl(fd, F_NOCACHE, 1)
    except OSError: pass


def write_file():
    os.makedirs(TMPDIR, exist_ok=True)
    buf = os.urandom(32 << 20)
    written = 0; fd = os.open(PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    t = time.perf_counter()
    try:
        while written < SIZE:
            written += os.write(fd, buf)
        os.fsync(fd)
    finally:
        os.close(fd)
    dt = time.perf_counter() - t
    return {"GBps": round(SIZE / 1e9 / dt, 3), "seconds": round(dt, 1)}


def rand_read(block, n_reads):
    fd = os.open(PATH, os.O_RDONLY); _nocache(fd)
    maxoff = SIZE - block
    lat = []; total = 0; t0 = time.perf_counter()
    try:
        for _ in range(n_reads):
            off = random.randrange(0, maxoff) & ~0xFFF
            t = time.perf_counter(); b = os.pread(fd, block, off)
            lat.append(time.perf_counter() - t); total += len(b)
    finally:
        os.close(fd)
    dt = time.perf_counter() - t0; lat.sort()
    return {"block_bytes": block, "block_MiB": round(block/1048576, 3), "n": n_reads,
            "GBps": round(total / 1e9 / dt, 3), "IOPS": round(n_reads / dt, 1),
            "lat_ms_p50": round(lat[len(lat)//2]*1e3, 3),
            "lat_ms_p95": round(lat[min(int(len(lat)*0.95), len(lat)-1)]*1e3, 3),
            "lat_ms_max": round(lat[-1]*1e3, 3)}


def seq_read(block=32 << 20):
    fd = os.open(PATH, os.O_RDONLY); _nocache(fd)
    total = 0; t = time.perf_counter()
    try:
        while True:
            b = os.read(fd, block)
            if not b: break
            total += len(b)
    finally:
        os.close(fd)
    dt = time.perf_counter() - t
    return {"block_bytes": block, "GBps": round(total / 1e9 / dt, 3), "seconds": round(dt, 1)}


try:
    OUT["sequential_write"] = write_file()
    # RANDOM FIRST — earlier file regions already evicted by the 40 GiB write stream.
    OUT["random_read_cold"] = [rand_read(bs, n) for bs, n in
                               [(64<<10, 400), (256<<10, 400), (1<<20, 300),
                                (4<<20, 200), (16<<20, 100), (64<<20, 40)]]
    OUT["sequential_read_cold"] = seq_read()   # 40 GiB > RAM ⇒ disk-bound
finally:
    shutil.rmtree(TMPDIR, ignore_errors=True)
    OUT["cleanup"] = "removed " + TMPDIR

print(json.dumps(OUT, indent=2))
