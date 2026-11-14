#!/usr/bin/env python3
"""Re-runnable validated-model catalog harness.

For each candidate model in candidates.json: provision -> load -> run a tiny REAL job through the SAME bridge
command the EshMacCapabilities host runs -> check the output -> record what was observed into the shipped
catalog (Sources/EshMacCapabilities/Resources/catalog/validated-models.json), which EshMacCapabilities exposes
to consumers (Esh Studio) as per-model options + live readiness.

Run it with the interpreter of the venv you want to validate (it must have the engine's base deps; the
harness can install per-model extras with --provision):

    ~/.esh/validation/venv/bin/python scripts/model-catalog/validate.py --provision
    ... --only mlx-community/csm-1b-8bit --force        # re-validate one model
    ... --capability audio.transcribe --max 3            # cap a pass

Idempotent: an entry already validated against the same mlx_audio version is skipped unless --force.
Weights go to the configured assets volume (~/.esh/storage.json `assetsRoot`, i.e. the external SSD) in the
same Hugging Face cache layout the host uses, so validated weights are reused by the app, never re-fetched.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import math
import os
import re
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
BRIDGE = REPO / "Sources" / "EshMacCapabilities" / "Resources" / "bridge" / "mlx_vlm_bridge.py"
CATALOG = REPO / "Sources" / "EshMacCapabilities" / "Resources" / "catalog" / "validated-models.json"
CANDIDATES = Path(__file__).with_name("candidates.json")

# The STT model used to round-trip-check TTS output (fast, validated, commercial-safe).
REFERENCE_STT = "mlx-community/parakeet-tdt-0.6b-v2"
SAMPLE_SENTENCE = "The quick brown fox jumps over the lazy dog."
STT_FIXTURE_SENTENCE = "The quick brown fox jumps over the lazy dog. Every model is checked before it ships."
PASS_OVERLAP = 0.6
MAC_MEMORY_TIERS_GB = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192]
OS_APP_HEADROOM_GB = 6.0

# Import name -> pip requirement, for --auto-deps discovery of a model's extra packages.
PIP_FOR_MODULE = {
    "misaki": "misaki>=0.9.4",
    "espeakng_loader": "espeakng-loader",
    "phonemizer": "phonemizer-fork",
    "en_core_web_sm": "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/"
                      "en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl",
    "dac": "descript-audio-codec",
    "mistral_common": "mistral-common[audio]",
    "sklearn": "scikit-learn",
    "cv2": "opencv-python",
    "PIL": "pillow",
    "yaml": "pyyaml",
}
COMMERCIAL_LICENSES = {"apache-2.0", "mit", "bsd-2-clause", "bsd-3-clause", "cc-by-4.0", "cc-by-sa-4.0",
                       "cc0-1.0", "unlicense", "isc", "openrail", "openrail++", "creativeml-openrail-m"}


# --------------------------------------------------------------------------------------------- helpers

def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def assets_root() -> Path:
    env = os.environ.get("ESH_ASSETS_HOME")
    if env:
        return Path(env)
    cfg = Path.home() / ".esh" / "storage.json"
    if cfg.exists():
        root = json.loads(cfg.read_text()).get("assetsRoot")
        if root:
            return Path(root)
    return Path.home() / ".esh"


def hf_cache(family: str) -> Path:
    """Mirror PersistenceRoot.pythonHFCacheURL(family:) — caches/<family>-models on the assets volume."""
    return assets_root() / "caches" / f"{family}-models"


def repo_cache_dir(cache: Path, repo: str) -> Path:
    return cache / "hub" / ("models--" + repo.replace("/", "--"))


def dir_bytes(path: Path) -> int:
    """On-disk bytes of a HF repo cache dir (blobs are the real files; snapshots are symlinks)."""
    blobs = path / "blobs"
    if not blobs.exists():
        return 0
    return sum(f.stat().st_size for f in blobs.iterdir() if f.is_file() and not f.name.startswith("._"))


def hub_repos(cache: Path) -> set[str]:
    hub = cache / "hub"
    if not hub.exists():
        return set()
    return {d.name for d in hub.iterdir() if d.name.startswith("models--")}


def machine() -> str:
    def sysctl(key: str) -> str:
        try:
            return subprocess.check_output(["sysctl", "-n", key], text=True).strip()
        except Exception:  # noqa: BLE001
            return ""
    mem = sysctl("hw.memsize")
    gb = f", {int(mem) // 1024**3} GB" if mem.isdigit() else ""
    return f"{sysctl('machdep.cpu.brand_string') or 'Apple silicon'}{gb}"


def runtime_versions() -> dict[str, str]:
    from importlib.metadata import PackageNotFoundError, version
    out = {"python": ".".join(map(str, sys.version_info[:3]))}
    for pkg, key in (("mlx-audio", "mlxAudio"), ("mlx", "mlx"), ("mlx-lm", "mlxLm"), ("transformers", "transformers")):
        try:
            out[key] = version(pkg)
        except PackageNotFoundError:
            pass
    return out


def module_available(module: str) -> bool:
    return subprocess.run([sys.executable, "-c", f"import {module}"], capture_output=True).returncode == 0


def pip_install(requirements: list[str]) -> tuple[bool, str]:
    proc = subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", *requirements],
                          capture_output=True, text=True)
    return proc.returncode == 0, (proc.stderr or proc.stdout)[-600:]


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def overlap(expected: str, got: str) -> float:
    exp = words(expected)
    have = set(words(got))
    return 0.0 if not exp else sum(1 for w in exp if w in have) / len(exp)


def read_wav_stats(path: Path) -> dict[str, Any]:
    """Duration / RMS / peak of a WAV (PCM 16/24/32 or float32, incl. WAVE_FORMAT_EXTENSIBLE). Stdlib only."""
    data = path.read_bytes()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    pos, fmt, pcm = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, ch, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE and len(body) >= 26:
                tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, ch, rate, bits)
        elif cid == b"data":
            pcm = body
        pos += 8 + size + (size & 1)
    if not fmt or pcm is None:
        raise ValueError("missing fmt/data chunk")
    tag, ch, rate, bits = fmt
    width = bits // 8
    frames = len(pcm) // (width * ch) if width and ch else 0
    step = max(1, (frames * ch) // 200_000)  # subsample long clips
    vals: list[float] = []
    for i in range(0, frames * ch, step):
        chunk = pcm[i * width:(i + 1) * width]
        if tag == 3 and width == 4:
            vals.append(struct.unpack("<f", chunk)[0])
        elif width == 2:
            vals.append(struct.unpack("<h", chunk)[0] / 32768.0)
        elif width == 3:
            vals.append(int.from_bytes(chunk, "little", signed=True) / 8388608.0)
        elif width == 4:
            vals.append(struct.unpack("<i", chunk)[0] / 2147483648.0)
    rms = math.sqrt(sum(v * v for v in vals) / len(vals)) if vals else 0.0
    return {"seconds": round(frames / rate, 2) if rate else 0.0, "sampleRate": rate, "channels": ch,
            "rms": round(rms, 4), "peak": round(max((abs(v) for v in vals), default=0.0), 4)}


def stt_fixture(work: Path) -> Path:
    """A deterministic English speech clip from macOS `say` (no network) at 16 kHz mono PCM16."""
    out = work / "stt-fixture.wav"
    if not out.exists():
        subprocess.run(["say", "-o", str(out), "--data-format=LEI16@16000", STT_FIXTURE_SENTENCE], check=True)
    return out


def run_bridge(command: str, request: dict[str, Any], log_path: Path, timeout: int) -> dict[str, Any]:
    """Run one bridge command under /usr/bin/time -l (peak memory footprint), exactly as the host would."""
    started = time.time()
    proc = subprocess.run(["/usr/bin/time", "-l", sys.executable, str(BRIDGE), command],
                          input=json.dumps(request), capture_output=True, text=True, timeout=timeout)
    elapsed = time.time() - started
    stderr = proc.stderr or ""
    with log_path.open("a") as fh:
        fh.write(f"\n===== {command} {json.dumps(request)}\n--- exit {proc.returncode} in {elapsed:.1f}s\n")
        fh.write("--- stdout\n" + (proc.stdout or "") + "\n--- stderr\n" + stderr + "\n")
    peak = re.search(r"(\d+)\s+peak memory footprint", stderr)
    rss = re.search(r"(\d+)\s+maximum resident set size", stderr)
    # Strip the time(1) report so the reason is the bridge's own last line.
    body = [l for l in stderr.splitlines() if not re.match(r"^\s*\d+(\.\d+)?\s+[a-z]", l)
            and "Fetching" not in l and "real" not in l[:12]]
    payload: dict[str, Any] = {}
    try:
        payload = json.loads((proc.stdout or "").strip().splitlines()[-1]) if proc.stdout.strip() else {}
    except Exception:  # noqa: BLE001
        payload = {}
    return {"ok": proc.returncode == 0, "seconds": round(elapsed, 1),
            "peakBytes": int(peak.group(1)) if peak else (int(rss.group(1)) if rss else None),
            "reason": (body[-1].strip() if body else "")[:400], "payload": payload, "stderr": stderr}


def classify_failure(reason: str, stderr: str) -> tuple[str, str | None]:
    text = reason + "\n" + stderr
    missing = re.search(r"No module named '([^']+)'", text)
    if missing:
        return "needs-deps", missing.group(1).split(".")[0]
    if re.search(r"(not supported|unsupported model|Unknown model type|model_type .* not|has no attribute 'Model')",
                 text, re.IGNORECASE):
        return "unsupported", None
    return "failed", None


def recommended_memory_gb(peak_bytes: int | None) -> int | None:
    if not peak_bytes:
        return None
    need = peak_bytes / 1024**3 + OS_APP_HEADROOM_GB
    return next((t for t in MAC_MEMORY_TIERS_GB if t >= need), MAC_MEMORY_TIERS_GB[-1])


def hf_facts(repo: str) -> dict[str, Any]:
    try:
        from huggingface_hub import HfApi
        info = HfApi().model_info(repo, files_metadata=True)
    except Exception as exc:  # noqa: BLE001
        return {"error": f"{type(exc).__name__}: {exc}"[:200]}
    card = getattr(info, "card_data", None) or {}
    lic = (card.get("license") if hasattr(card, "get") else None) or next(
        (t.split(":", 1)[1] for t in (info.tags or []) if t.startswith("license:")), None)
    return {"weightBytes": sum((s.size or 0) for s in (info.siblings or [])) or None,
            "license": lic, "gated": bool(getattr(info, "gated", False)),
            "downloads": getattr(info, "downloads", None), "likes": getattr(info, "likes", None),
            "sha": getattr(info, "sha", None)}


def commercial(license_id: str | None) -> bool | None:
    if not license_id:
        return None
    lid = license_id.lower()
    if "nc" in lid.split("-") or "non-commercial" in lid or "noncommercial" in lid or "research" in lid:
        return False
    return True if lid in COMMERCIAL_LICENSES else None


# --------------------------------------------------------------------------------------------- checks

def check_output(cand: dict[str, Any], out: Path, work: Path, logp: Path, timeout: int) -> tuple[bool, str]:
    kind = cand["check"]
    if not out.exists() or out.stat().st_size == 0:
        return False, "no output file"
    if kind in ("tts-roundtrip", "wav-nonsilent"):
        st = read_wav_stats(out)
        if st["seconds"] < 0.5 or st["rms"] < 0.003:
            return False, f"audio is empty/silent ({st})"
        if kind == "wav-nonsilent":
            return True, f"{st['seconds']}s @ {st['sampleRate']} Hz, rms {st['rms']}"
        tr = run_bridge("speech-transcribe", {"audioPath": str(out), "outputPath": str(out.with_suffix(".txt")),
                                              "model": REFERENCE_STT, "hfCache": str(hf_cache("audio"))},
                        logp, timeout)
        text = tr["payload"].get("text", "") if tr["ok"] else ""
        score = overlap(cand.get("sampleText", SAMPLE_SENTENCE), text)
        return score >= PASS_OVERLAP, (f"{st['seconds']}s @ {st['sampleRate']} Hz; round-trip via {REFERENCE_STT}: "
                                       f"\"{text}\" (word overlap {score:.2f})")
    if kind == "stt-fixture":
        text = out.read_text(encoding="utf-8").strip()
        score = overlap(STT_FIXTURE_SENTENCE, text)
        return score >= PASS_OVERLAP, f"\"{text}\" (word overlap {score:.2f} vs the `say` fixture)"
    if kind == "file-nonempty":
        return True, f"{out.stat().st_size} bytes"
    raise ValueError(f"unknown check {kind}")


def build_request(cand: dict[str, Any], out: Path, work: Path) -> dict[str, Any]:
    req: dict[str, Any] = {"model": cand["id"], "outputPath": str(out),
                           "hfCache": str(hf_cache(cand.get("cacheFamily", "audio")))}
    if cand["check"] == "stt-fixture":
        req["audioPath"] = str(stt_fixture(work))
    else:
        req["text"] = cand.get("sampleText", SAMPLE_SENTENCE)
    req.update(cand.get("requiredArgs", {}))
    return req


# --------------------------------------------------------------------------------------------- main

def validate(cand: dict[str, Any], args: argparse.Namespace, work: Path, prior: dict[str, Any] | None) -> dict[str, Any]:
    slug = cand["id"].replace("/", "__")
    logp = work / "logs" / f"{slug}.log"
    logp.parent.mkdir(parents=True, exist_ok=True)
    cache = hf_cache(cand.get("cacheFamily", "audio"))
    facts = hf_facts(cand["id"])
    extras: list[dict[str, str]] = list(cand.get("extraPackages", []))

    # Provision declared extras first.
    for pkg in extras:
        if not module_available(pkg["module"]):
            if not args.provision:
                break
            ok, err = pip_install([pkg["pip"]])
            log(f"   provision {pkg['pip']}: {'ok' if ok else 'FAILED ' + err}")

    before = hub_repos(cache)
    out = work / "outputs" / f"{slug}.{cand['outputExt']}"
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    request = build_request(cand, out, work)
    status, missing, result = "failed", None, None
    for _attempt in range(5):
        result = run_bridge(cand["bridgeCommand"], request, logp, args.timeout)
        if result["ok"]:
            break
        status, missing = classify_failure(result["reason"], result["stderr"])
        if status == "needs-deps" and missing and args.auto_deps:
            pip_req = PIP_FOR_MODULE.get(missing, missing.replace("_", "-"))
            ok, err = pip_install([pip_req])
            log(f"   auto-dep {missing} -> {pip_req}: {'ok' if ok else 'FAILED ' + err}")
            if ok:
                extras.append({"module": missing, "pip": pip_req})
                continue
        break

    sample_ok, sample_note = False, ""
    warm = None
    if result and result["ok"]:
        try:
            sample_ok, sample_note = check_output(cand, out, work, logp, args.timeout)
        except Exception as exc:  # noqa: BLE001
            sample_ok, sample_note = False, f"output check crashed: {exc}"
        status = "ok" if sample_ok else "failed"
        if sample_ok and result["seconds"] < 300 and not args.no_warm:
            w = run_bridge(cand["bridgeCommand"], request, logp, args.timeout)
            warm = w["seconds"] if w["ok"] else None

    after = hub_repos(cache)
    primary = repo_cache_dir(cache, cand["id"])
    aux_names = sorted((after - before) - {primary.name}) or (prior or {}).get("auxiliaryCacheDirs", [])
    aux = [{"repo": n.removeprefix("models--").replace("--", "/"), "bytes": dir_bytes(cache / "hub" / n)}
           for n in aux_names]
    primary_bytes = dir_bytes(primary) or None
    peak = result["peakBytes"] if result else None
    lic = facts.get("license") or cand.get("license")  # the model card wins; candidate = upstream fallback
    versions = runtime_versions()
    entry = {
        "id": cand["id"],
        "capability": cand["capability"],
        "engine": cand["engine"],
        "family": cand["family"],
        "displayName": cand["displayName"],
        "rank": cand["rank"],
        "isDefault": bool(cand.get("isDefault")),
        "status": status,
        "extraPackages": extras,
        "requiredArgs": cand.get("requiredArgs", {}),
        "weightBytes": facts.get("weightBytes"),
        "firstRunDownloadBytes": (primary_bytes or 0) + sum(a["bytes"] for a in aux) or None,
        "auxiliaryDownloads": aux,
        "peakMemoryBytes": peak,
        "recommendedMinMemoryGB": recommended_memory_gb(peak) if status == "ok" else None,
        "minChip": "Apple silicon (M1 or later)",
        "license": lic,
        "commercialUse": cand.get("commercialUse", commercial(lic)),
        "licenseNote": cand.get("licenseNote"),
        "gated": facts.get("gated", False),
        "sampleOutputOK": sample_ok,
        "sampleCheck": sample_note or None,
        "coldRunSeconds": result["seconds"] if result else None,
        "warmRunSeconds": warm,
        "error": None if status == "ok" else ((result or {}).get("reason") or "no result"),
        "missingModule": missing if status == "needs-deps" else None,
        "note": cand.get("note"),
        "lastValidated": {"date": _dt.date.today().isoformat(), "machine": machine(), **versions},
        "auxiliaryCacheDirs": aux_names,
    }
    return entry


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--candidates", type=Path, default=CANDIDATES)
    ap.add_argument("--catalog", type=Path, default=CATALOG)
    ap.add_argument("--work-dir", type=Path, default=None, help="logs/outputs (default: <assetsRoot>/validation)")
    ap.add_argument("--only", nargs="*", default=None, help="validate only these repo ids")
    ap.add_argument("--capability", default=None)
    ap.add_argument("--max", type=int, default=None, help="cap the number of candidates this pass")
    ap.add_argument("--force", action="store_true", help="re-validate even if cached for this runtime version")
    ap.add_argument("--provision", action="store_true", help="pip-install declared extra packages")
    ap.add_argument("--auto-deps", action="store_true", help="install + record missing modules discovered at run")
    ap.add_argument("--no-warm", action="store_true", help="skip the warm (cached-weights) timing run")
    ap.add_argument("--timeout", type=int, default=1800)
    args = ap.parse_args()
    if args.auto_deps:
        args.provision = True

    work = args.work_dir or (assets_root() / "validation")
    work.mkdir(parents=True, exist_ok=True)
    spec = json.loads(args.candidates.read_text())
    cands = sorted(spec["candidates"], key=lambda c: (c["capability"], c["rank"]))
    if args.only:
        cands = [c for c in cands if c["id"] in set(args.only)]
    if args.capability:
        cands = [c for c in cands if c["capability"] == args.capability]
    if args.max:
        cands = cands[: args.max]

    catalog = json.loads(args.catalog.read_text()) if args.catalog.exists() else {"entries": []}
    index = {(e["id"], e["capability"]): e for e in catalog.get("entries", [])}
    versions = runtime_versions()
    log(f"esh model-catalog validation — {machine()} — {versions} — assets {assets_root()}")

    for cand in cands:
        key = (cand["id"], cand["capability"])
        prior = index.get(key)
        if (prior and not args.force and prior.get("status") in ("ok", "unsupported")
                and prior.get("lastValidated", {}).get("mlxAudio") == versions.get("mlxAudio")):
            log(f"== {cand['id']} [{cand['capability']}] cached ({prior['status']}, {prior['lastValidated']['date']})")
            continue
        log(f"== {cand['id']} [{cand['capability']}] ...")
        entry = validate(cand, args, work, prior)
        index[key] = entry
        log(f"   -> {entry['status']}  peak={entry['peakMemoryBytes']}  dl={entry['firstRunDownloadBytes']}  "
            f"cold={entry['coldRunSeconds']}s  {entry['sampleCheck'] or entry['error']}")
        # Persist after every model so an interrupted pass keeps what it learned (idempotent re-run resumes).
        write_catalog(args.catalog, index, versions)
    write_catalog(args.catalog, index, versions)


def write_catalog(path: Path, index: dict[tuple[str, str], dict[str, Any]], versions: dict[str, str]) -> None:
    entries = sorted(index.values(), key=lambda e: (e["capability"], e["rank"], e["id"]))
    doc = {
        "schemaVersion": 1,
        "updatedAt": _dt.date.today().isoformat(),
        "generatedWith": versions,
        "validatedOn": machine(),
        "harness": "scripts/model-catalog/validate.py",
        "entries": entries,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2, sort_keys=False) + "\n")


if __name__ == "__main__":
    main()
