# Esh

Esh is a local-first LLM tool for Apple Silicon.

It gives you:
- local model install and management
- interactive terminal chat
- stable JSON commands for external callers
- saved sessions
- backend-native execution cache export/import
- TurboQuant cache compression for MLX
- self-contained release packaging

Today, Esh is built around an MLX backend with a Swift core and CLI/TUI, plus a small Python bridge for `mlx-lm` and `mlx-vlm`.

## Planning Notes

Durable engineering notes live in:
- [docs/PLANNING.md](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/docs/PLANNING.md)

## What Esh Is For

Esh is designed for people who want a local chat tool that is:
- fast to run from terminal
- practical for repeated conversations
- honest about model and cache compatibility
- ready to grow into more backends later

This is a text-chat tool in v1.

It does not yet do:
- document ingestion
- codebase indexing
- embeddings or RAG
- multimodal chat
- in-tool model install directly from arbitrary search results outside local installs and Hugging Face

## Quick Start

### Install and run

For end users on macOS, the one-line install and run command is:

```bash
brew tap fil-technology/tap && brew install --cask esh && esh
```

If `brew` is not installed yet, install Homebrew first:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install and run Esh:

```bash
brew tap fil-technology/tap && brew install --cask esh && esh
```

If you prefer the steps split out:

```bash
brew tap fil-technology/tap
brew install --cask esh
esh
```

Upgrade later with:

```bash
brew upgrade --cask esh
```

If you previously tried the older formula-based install, remove it first:

```bash
brew uninstall esh
brew install --cask esh
```

### Developer mode

Bootstrap once:

```bash
./scripts/bootstrap.sh
```

Then use the stable launcher:

```bash
./esh
./esh doctor
./esh model list
./esh chat
```

Running `./esh` with no command opens a default interactive launcher menu with the most common actions.

### External callers

Use `esh capabilities` to get a JSON map of supported backends, installed models, and whether each path supports direct inference, cache build, and cache load.

Use `esh infer` for machine-friendly inference. It returns JSON for both MLX and GGUF models, and MLX cache load stays optional rather than being the only supported integration path.

```bash
./esh capabilities
cat <<'JSON' | ./esh infer --input -
{
  "schemaVersion": "esh.infer.request.v1",
  "model": "mlx-community--qwen2.5-0.5b-instruct-4bit",
  "messages": [
    { "role": "user", "text": "Say hello in one sentence." }
  ],
  "generation": {
    "maxTokens": 64,
    "temperature": 0.2
  }
}
JSON
```

### Release mode

Build a self-contained release bundle:

```bash
./scripts/package-release.sh
```

Run the packaged tool:

```bash
./dist/esh-macos-<version>/esh doctor
./dist/esh-macos-<version>/esh chat
```

## GitHub CI/CD

Esh includes GitHub Actions workflows for continuous integration and release packaging.

CI workflow:
- [ci.yml](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/.github/workflows/ci.yml)

Release workflow:
- [release.yml](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/.github/workflows/release.yml)

What they do:
- CI runs on pushes to `main` and on pull requests
- release packaging runs for tags like `v0.1.0`
- release packaging can also be started manually from GitHub Actions
- macOS release builds upload the package as an artifact, publish both a notarized `.zip` and a `.tar.gz` plus SHA-256 checksums on the GitHub release, and push the same bundle to GitHub Packages through GHCR
- tagged releases can also update the Homebrew tap cask automatically when `HOMEBREW_TAP_TOKEN` is configured in repo secrets

## Versioning and Releases

Esh uses semantic versions stored in:
- [VERSION](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/VERSION)
- [CHANGELOG.md](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/CHANGELOG.md)

Helpful commands:

```bash
./scripts/release-version.sh show
./scripts/release-version.sh tag
./scripts/release-version.sh verify-tag v0.1.0
```

Suggested release flow:

```bash
./scripts/release-version.sh show
git tag "$(./scripts/release-version.sh tag)"
git push origin "$(./scripts/release-version.sh tag)"
```

The GitHub release workflow verifies that the pushed tag matches `VERSION`.

GitHub surfaces:
- `Releases` shows downloadable end-user artifacts like `esh-macos-0.1.14.zip`
- `Packages` shows the same packaged bundle published to GHCR as `ghcr.io/fil-technology/esh/esh-macos:<version>`

## Install a Model

Esh now has a built-in shortlist of recommended stable models for fast first-time setup.

Start there:

```bash
./esh model recommended
./esh model recommended --profile chat
./esh model install fast-chat
```

You can still install directly from a Hugging Face repo id too.

You can search first:

```bash
./esh model search qwen
./esh model search qwen --source local
./esh model search qwen --source hf --limit 5
```

Example:

```bash
./esh model install mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

Check a model before downloading it:

```bash
./esh model check mlx-community/Qwen2.5-7B-Instruct-4bit --backend mlx
./esh model check bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF --backend gguf --context 8192
./esh model check bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF --backend gguf --variant Q4_K_M
./esh model check mlx-community/gemma-4-27b-it-4bit --json
```

Then inspect what is installed:

```bash
./esh model list
./esh model list --task audio
./esh model list --capability tts
./esh model inspect mlx-community--qwen2.5-0.5b-instruct-4bit
```

Notes:
- the install command accepts either a Hugging Face repo id or a built-in alias like `fast-chat`
- `model check` is heuristic: it estimates likely backend support and likely fit, not a guarantee
- `model check --backend auto` resolves the backend from repo metadata and filenames when it can
- `model check` and `model install` accept `--variant <name>` for GGUF quant variants and other explicit repo variants
- initial GGUF support is wired through llama.cpp and is currently text-only
- GGUF install/runtime support is intentionally narrow in this pass: it prefers a single clear GGUF candidate and reports ambiguity instead of guessing
- inspect/remove/chat/cache commands accept the installed model id and also the original repo id where practical
- installed ids are normalized like `mlx-community--qwen2.5-0.5b-instruct-4bit`

## Audio

List MLX text-to-speech models exposed through TTSMLX:

```bash
./esh audio models
```

The interactive launcher (`./esh`) also has an **Audio** entry for generating WAV files through the same MLX TTS path.

Generate a WAV file with an MLX TTS model:

```bash
./esh audio speak "Hello from esh" --model pocket-tts --voice alba --out hello.wav
./esh audio speak "Hello from esh" --model Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit --play
```

The first run downloads the selected TTS model into `.esh/tts-models`. Speech-to-text is still a planned backend slice; `audio transcribe` currently reports that STT is not wired yet.

## Chat

Launch chat:

```bash
./esh chat
```

Or just run:

```bash
./esh
```

and choose `1. Chat` from the default menu.

Launch or reopen a named session:

```bash
./esh chat default
./esh chat work
./esh chat experiments
./esh chat work --model mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

Inside chat, you can type normal messages and slash commands.

Example:

```text
> hello how are you, what can you do?
> /autosave on
> /sessions
> /new scratch
> /switch default
> /save
> /exit
```

## TUI Features

The chat UI includes:
- transcript pane
- fixed input bar
- fixed footer stats
- command overlay
- saved session switching from inside chat

Useful slash commands:

```text
/menu
/help
/save
/autosave on
/autosave off
/autosave toggle
/new
/new my-session
/switch my-session
/switch <uuid>
/models
/use-model <id-or-repo>
/model current
/sessions
/caches
/search <text>
/doctor
/model inspect <id>
/session show <uuid-or-name>
/cache inspect <uuid>
/close
/exit
```

## Sessions

List sessions from the CLI:

```bash
./esh session list
```

Show a specific saved session:

```bash
./esh session show <session-uuid>
./esh session show default
./esh session grep hello
```

The chat UI shows sessions in a more human-friendly way:
- session name
- short id
- message count

Example:

```text
default [8C56AF77] | 2 messages
lifecycle [D59E570E] | 2 messages
demo-session [2AB2CAF3] | 2 messages
```

## Cache Workflows

Esh supports:
- raw cache artifacts
- TurboQuant-compressed cache artifacts
- cache inspect
- cache load and resume

List saved cache artifacts:

```bash
./esh cache inspect
```

Inspect one artifact:

```bash
./esh cache inspect C46B9A7C-0636-4111-B300-C5A9AE1341C1
```

Build a cache from a saved session:

```bash
./esh session list
./esh cache build --session <session-uuid> --mode raw
./esh cache build --session <session-uuid> --mode turbo
```

Resume from a saved cache:

```bash
./esh cache load --artifact <artifact-uuid> --message "Continue this chat"
```

Important:
- cache artifacts are backend-specific
- cache artifacts are model-specific
- Esh reuses one cache pipeline, but artifacts are not portable across runtimes/models

## Typical Use Cases

### 1. Quick local chat

```bash
./scripts/bootstrap.sh
./esh model install mlx-community/Qwen2.5-0.5B-Instruct-4bit
./esh chat
```

### 2. Keep multiple named chats

```bash
./esh chat work
./esh chat ideas
./esh chat debugging
```

Or from inside chat:

```text
/new work
/switch ideas
/sessions
```

### 3. Save a conversation state and benchmark cache modes

```bash
./esh session list
./esh cache build --session <session-uuid-or-name> --mode raw
./esh cache build --session <session-uuid-or-name> --mode turbo
./esh cache inspect
```

## Benchmarking

Compare raw and TurboQuant cache behavior for the same session:

```bash
./esh benchmark --session model-flag-smoke --model mlx-community/Qwen2.5-0.5B-Instruct-4bit --message "Continue with one short sentence about local AI."
./esh benchmark history
```

### 4. Compare raw vs turbo on a real saved session

```bash
./esh benchmark --session default --model mlx-community/Qwen2.5-0.5B-Instruct-4bit
./esh benchmark history
```

### 5. Verify environment health before debugging

```bash
./esh doctor
./scripts/verify-env.sh
```

## Data Layout

By default, Esh stores data under:

```text
~/.esh
```

This includes separate locations for:
- models
- sessions
- caches

Override the root if needed:

```bash
ESH_HOME=/path/to/custom-root ./esh chat
```

Esh also accepts legacy `LLMCACHE_*` env vars for compatibility during the rename transition.

## Project Layout

- [Package.swift](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/Package.swift)
- [Sources/EshCore](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/Sources/EshCore)
- [Sources/esh](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/Sources/esh)
- [Tools/mlx_vlm_bridge.py](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/Tools/mlx_vlm_bridge.py)
- [scripts/bootstrap.sh](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/scripts/bootstrap.sh)
- [scripts/package-release.sh](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/scripts/package-release.sh)
- [docs/USAGE.md](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/docs/USAGE.md)

## Current Limitations

These are the most important current caveats:

- model search covers installed models and Hugging Face, but install still happens by explicit repo id
- cache artifacts remain runtime/model specific and are not cross-backend portable
- some build runs still show Swift concurrency warnings from `ProcessRunner.swift`, but the tool functions correctly

## More Detailed Guide

See the full guide at [docs/USAGE.md](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Coding/MLX+TurboQuant/Source/docs/USAGE.md).
