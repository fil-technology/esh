# esh 2.0.0 — Security & Privacy Review (Phase O)

**Date:** 2026-09-01
**Scope:** the `esh` CLI, its local OpenAI-compatible server, the Web Chat reference client, the
model download path, and the MLX/GGUF/Apple runtimes. Grounded in code inspected this session.

## Executive summary

esh is a **local-first, on-device intelligence engine**. Inference never leaves the machine; there is
**no telemetry, analytics, or phone-home**. The only outbound network calls are (1) model downloads
from Hugging Face and (2) an opt-in GitHub release-version check. The local API server binds to
**loopback by default** and refuses non-local clients unless the operator explicitly opts into a
wildcard host. No high-severity issues were found. A few hardening recommendations are listed.

---

## 1. Data flow & privacy

| Concern | Finding |
|---|---|
| Inference location | 100% on-device (MLX/llama.cpp/Apple FoundationModels). No prompt or completion is sent to any cloud service. |
| Monetary cost / provenance | Local runs report `monetaryCostUSD = 0` with on-device provenance (test-enforced: `localUsageHasZeroMonetaryCostWithProvenance`). Never fabricated. |
| Telemetry / analytics | **None.** No PostHog/Segment/Sentry/Amplitude/etc. No usage beacons. (grep across `Sources` clean.) |
| Outbound hosts | Only `huggingface.co` (+ `/api/models`) for model downloads/metadata, and `api.github.com/repos/fil-technology/esh/releases/latest` for the opt-in update check. Documentation URLs are shown, not fetched. |
| Web Chat history | Stored **client-side only** in the browser's `localStorage`; the server does not persist conversations. Clearing browser data removes it. |
| User email / identity | Not collected. No account, no login. |
| Attachments | Honestly **rejected** on the inference path (not silently uploaded anywhere). |

## 2. Local server exposure

| Concern | Finding |
|---|---|
| Default bind | `127.0.0.1` (loopback). `esh web` and `esh serve` both default to local only. |
| Non-local clients | `isEndpointAllowed` enforces loopback: in loopback mode only `127.0.0.1`/`::1` are accepted; other remotes get 401. Wildcard (`0.0.0.0`/`::`) is an explicit operator choice. |
| Authentication | `esh serve --api-key <token>` enables bearer-token auth (constant-time-ish exact match). `esh web` intentionally runs **without** a token because the browser needs same-origin unauthenticated access — acceptable **only** because it is loopback-bound. |
| CORS | The API sets permissive `access-control-allow-origin: *`. On a loopback server this is low-risk, but see recommendations. |
| Request size | Body is read up to `content-length`; the receive loop caps chunks at 64 KB and accumulates — a very large `content-length` could grow memory (see recommendations). |

## 3. Supply chain & runtime

| Concern | Finding |
|---|---|
| Model downloads | From Hugging Face over HTTPS. Downloader validates downloaded file size against metadata (`installFailsWhenDownloadedFileSizeDoesNotMatchMetadata`). |
| Model provenance | Curated catalog pins specific repo IDs. Known-broken models are gated (`.incompatible`), never silently substituted. |
| Python bridge | MLX runs an out-of-process Python bridge from the repo/bundled `.venv`; `llama.cpp` uses `llama-completion`/`llama-cli`. Executable resolution honors `ESH_LLAMA_CPP_CLI`/`ESH_PYTHON`-style env overrides — an operator-controlled trust boundary. |
| Apple backend | On-device only (FoundationModels). The contract enforces the on-device-only guarantee; PCC/cloud is not silently used. |
| Secrets | No secrets are logged. HF token (if provided for gated models) is passed through, not persisted in plaintext by esh beyond the user's own config. |

## 4. Findings

**No high-severity issues.** Medium/low hardening recommendations:

1. **(low) CORS `*` on the local API.** Fine for loopback, but a browser page on any origin can call
   `http://127.0.0.1:<port>` while the server runs. Consider restricting `access-control-allow-origin`
   to the served page's origin, or gating non-GET routes behind the bearer token even on loopback.
2. **(low) Unauthenticated `esh web`.** Acceptable on loopback, but any local process/user on the
   machine can reach it. Document this; optionally support `esh web --api-key` for shared machines.
3. **(low) Request-body accumulation.** Enforce a maximum `content-length` (e.g. reject > N MB) to
   avoid a local client growing server memory with a huge declared body.
4. **(info) Wildcard bind warning.** When the operator chooses `0.0.0.0`/`::`, print a clear warning
   that the API (and any loaded model) is now reachable on the network, and recommend `--api-key`.
5. **(info) Update check is opt-in and notify-only** — it fetches only the latest version string and
   never auto-installs. Keep it that way.

## 5. Verdict

For a local, single-user tool, esh's privacy posture is **strong** (no telemetry, on-device
inference, loopback-by-default). The recommendations above are defense-in-depth for shared/multi-user
machines and network-exposed deployments; none block 2.0. Recommendations 1–4 are good 2.0-or-2.0.x
hardening items.
