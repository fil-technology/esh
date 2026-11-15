"""Provenance for benchmark results: which source revision, which binaries, which toolchain, which model weights.

Used by sdk_vs_serve.py so every result line says exactly what produced it, and so a stale prebuilt binary is never
reused silently: builds run by default, and a binary older than the sources it is built from is flagged (and refused
unless the caller explicitly allows it).
"""
from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path


def _run(cmd, cwd=None) -> str:
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def git_state(repo: Path) -> dict:
    """HEAD commit plus whether the working tree differs from it (tracked changes; a hash of the diff identifies them)."""
    status = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=repo,
                            capture_output=True, text=True).stdout   # not stripped: column 1 may be a space
    diff = subprocess.run(["git", "diff", "HEAD"], cwd=repo, capture_output=True).stdout
    return {
        "commit": _run(["git", "rev-parse", "HEAD"], cwd=repo),
        "branch": _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo),
        "dirty": bool(status),
        "dirtyFiles": [line[3:] for line in status.splitlines() if line][:50],
        "diffSha256": hashlib.sha256(diff).hexdigest() if diff else None,
    }


def file_identity(path: Path) -> dict:
    path = Path(path).resolve()
    if not path.is_file():
        return {"path": str(path), "exists": False}
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    st = path.stat()
    return {"path": str(path), "exists": True, "sha256": h.hexdigest(), "bytes": st.st_size,
            "modified": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(st.st_mtime))}


def newest_source(roots: list[Path]) -> tuple[float, str]:
    """Newest mtime among the Swift sources and manifests a binary is built from."""
    newest, which = 0.0, ""
    for root in roots:
        paths = [root] if root.is_file() else root.rglob("*")
        for p in paths:
            if p.is_file() and (p.suffix in {".swift", ".c", ".h", ".m", ".cpp", ".metal"} or
                                p.name in {"Package.swift", "Package.resolved"}):
                m = p.stat().st_mtime
                if m > newest:
                    newest, which = m, str(p)
    return newest, which


def staleness(binary: Path, roots: list[Path]) -> dict:
    """mtime-based and deliberately conservative: a branch switch that touches sources marks a binary stale even if
    its content would not change. Building (the default) is the way to get a binary known to match the sources."""
    if not binary.is_file():
        return {"stale": True, "reason": "binary missing"}
    newest, which = newest_source(roots)
    stale = binary.stat().st_mtime < newest
    return {"stale": stale, "newestSource": which if stale else None}


def swift_build(package_dir: Path, args: list[str]) -> dict:
    """Run `swift build` for a package and return timing + outcome; raises on failure (never benchmark a failed build)."""
    t0 = time.perf_counter()
    proc = subprocess.run(["swift", "build", *args], cwd=package_dir, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout[-4000:] + proc.stderr[-4000:])
        raise SystemExit(f"swift build {' '.join(args)} failed in {package_dir}")
    return {"command": f"swift build {' '.join(args)}", "cwd": str(package_dir),
            "seconds": round(time.perf_counter() - t0, 1)}


def bin_path(package_dir: Path) -> Path:
    return Path(_run(["swift", "build", "--show-bin-path"], cwd=package_dir))


def toolchain() -> dict:
    return {"swift": _run(["swift", "--version"]).splitlines()[0] if _run(["swift", "--version"]) else None,
            "xcodeSelect": _run(["xcode-select", "-p"])}


def host() -> dict:
    return {"macOS": platform.mac_ver()[0], "build": _run(["sw_vers", "-buildVersion"]),
            "chip": _run(["sysctl", "-n", "machdep.cpu.brand_string"]),
            "memoryBytes": int(_run(["sysctl", "-n", "hw.memsize"]) or 0)}


def python_runtime() -> dict:
    from importlib import metadata

    def version(name):
        try:
            return metadata.version(name)
        except metadata.PackageNotFoundError:
            return None
    return {"executable": sys.executable, "version": platform.python_version(),
            "mlx": version("mlx"), "mlx-lm": version("mlx-lm"), "mlx-vlm": version("mlx-vlm")}


def model_identity(store: Path, model_id: str) -> dict:
    """What the store says about an installed model: backend, format, source repo + revision, and the weight files.
    A Hugging Face revision pins the weights' content; without one (e.g. a direct GGUF download) each weight file is
    hashed instead, so the result still identifies the exact bytes."""
    manifest_path = store / "models" / "manifests" / f"{model_id}.json"
    if not manifest_path.is_file():
        return {"id": model_id, "manifest": None, "note": f"no manifest at {manifest_path}"}
    m = json.loads(manifest_path.read_text())
    inst = m.get("install", {})
    spec = inst.get("spec") or {}
    hf = inst.get("huggingFace") or {}
    source = spec.get("source") if isinstance(spec.get("source"), dict) else {}
    revision = hf.get("revision") or source.get("revision")
    install_path = Path(inst.get("installPath") or "")
    weights = []
    for name in m.get("files", []):
        p = install_path / name
        if p.suffix in {".safetensors", ".gguf"} and p.is_file():
            st = p.stat()
            entry = {"file": name, "bytes": st.st_size,
                     "modified": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(st.st_mtime))}
            if not revision:
                entry["sha256"] = file_identity(p)["sha256"]
            weights.append(entry)
    return {"id": model_id, "manifest": str(manifest_path), "backend": spec.get("backend"),
            "format": inst.get("backendFormat"), "runtime": inst.get("runtimeVersion"),
            "repo": hf.get("repoID") or source.get("repoID") or spec.get("baseModelID"), "revision": revision,
            "sizeBytes": inst.get("sizeBytes"), "installPath": str(install_path), "installedAt": inst.get("installedAt"),
            "weights": weights}
