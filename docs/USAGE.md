# Esh Usage Guide

This guide explains how to use Esh in day-to-day work.

## 1. Install and Run

### Dev mode

```bash
./scripts/bootstrap.sh
./esh
./esh doctor
./esh chat
```

What bootstrap does:
- creates or updates the local `.venv`
- installs pinned Python bridge dependencies
- builds the Swift CLI
- prepares the local runtime

Running `./esh` with no arguments opens the default interactive launcher menu.

### Release mode

```bash
./scripts/package-release.sh
./dist/esh-macos-<version>/share/esh/scripts/smoke-test-package.sh ./dist/esh-macos-<version>
./dist/esh-macos-<version>/esh doctor
./dist/esh-macos-<version>/esh chat
```

The package smoke test validates the packaged launcher and runtime layout. In headless or sandboxed macOS sessions where MLX cannot see a Metal GPU, the doctor check is reported as skipped while the non-GPU package checks still run.

The packaged release includes:
- `esh` launcher
- `bin/esh`
- embedded `python/`
- bridge scripts
- pinned Python dependencies

GitHub release publishing also pushes the packaged macOS bundle to GitHub Packages via GHCR, so the repo exposes both:
- a downloadable Release asset
- a versioned Package entry

## 2. Understand the Command Surface

Main commands:

```text
esh
esh chat [session-name] [--model <id-or-repo>]
esh benchmark --session <uuid-or-name> [--model <id-or-repo>] [--message <text>]
esh benchmark history
esh capabilities
esh doctor
esh infer --input <path-or->
esh infer --model <id-or-repo> --message <text> [--system <text>] [--artifact <uuid>] [--max-tokens N] [--temperature T] [--cache-mode raw|turbo|triattention|auto] [--intent chat|code|documentqa|agentrun|multimodal] [--session-name <name>]
esh model recommended [--profile chat|code]
esh model list
esh model search <query> [--source all|local|hf] [--limit N]
esh model check <model-or-repo> [--backend mlx|gguf|auto] [--context N] [--variant <name>] [--json] [--strict] [--offline]
esh model install <hf-repo-id-or-alias> [--variant <name>]
esh model inspect <model-id-or-repo>
esh model remove <model-id-or-repo>
esh session list
esh session show <uuid-or-name>
esh session grep <text>
esh cache build --session <uuid-or-name> [--mode raw|turbo] [--model <id-or-repo>]
esh cache load --artifact <uuid> --message <text> [--model <id-or-repo>]
esh cache inspect [artifact-uuid]
```

Plain `esh` opens a command menu with common actions like chat, model list, install model, sessions, caches, and doctor.

## 2a. External JSON Commands

Use these when another tool needs a stable machine-facing contract instead of human-readable text.

Inspect available integrations and installed-model support:

```bash
./esh capabilities
```

Launch supported external coding agents against local Esh-served models:

```bash
./esh integrations list
./esh integrations show codex
./esh integrations show claude
./esh integrations configure codex --model <installed-model-id>
./esh integrations configure claude --model <installed-model-id>
./esh serve --host 127.0.0.1 --port 11435
codex --profile esh-launch
./esh launch codex --model <installed-model-id>
./esh launch codex --model <installed-model-id> -- exec --ephemeral "Summarize this repository"
./esh launch claude --model <installed-model-id>
./esh launch claude --model <installed-model-id> -- -p "Explain this codebase" --output-format text
```

Run inference with JSON input from stdin or a file:

```bash
cat <<'JSON' | ./esh infer --input -
{
  "schemaVersion": "esh.infer.request.v1",
  "model": "mlx-community--qwen2.5-0.5b-instruct-4bit",
  "messages": [
    { "role": "system", "text": "Answer briefly." },
    { "role": "user", "text": "Say hello." }
  ],
  "generation": {
    "maxTokens": 64,
    "temperature": 0.2
  }
}
JSON
```

Notes:
- `esh infer` always returns JSON using `esh.infer.response.v1`
- direct inference works for both MLX and GGUF installs
- `cacheArtifactID` is optional and keeps MLX cache-load as an extra capability, not the only integration path
- `esh capabilities` reports which backends and installed models support direct inference versus cache build/load

## 3. Find and Install Models

Model workflow:
1. Start with built-in recommended models for the fastest setup.
2. Or search local installs and Hugging Face from Esh.
3. Install by alias or repo id.

Recommended presets:

```bash
./esh model recommended
./esh model recommended --profile chat
./esh model install fast-chat
./esh model install quality-code
```

Examples:

```bash
./esh model search qwen
./esh model search qwen --source local
./esh model search qwen --source hf --limit 5
```

Example:

```bash
./esh model install mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

Check before downloading:

```bash
./esh model check mlx-community/Qwen2.5-7B-Instruct-4bit --backend mlx
./esh model check bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF --backend gguf --context 8192
./esh model check bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF --backend gguf --variant Q4_K_M
./esh model check mlx-community/gemma-4-27b-it-4bit --json
```

What `model check` does:
- infers likely format, architecture, parameter size, and quantization from repo metadata
- checks backend compatibility separately from memory fit
- estimates a conservative local memory budget on the current Mac
- returns a heuristic verdict like `supported_and_likely_fits` or `insufficient_memory`

Notes:
- `supported` means the backend likely understands the model format and architecture
- `fits` means the estimated runtime memory stays under a conservative local safety budget
- `--strict` refuses positive verdicts when core metadata stays incomplete
- `--offline` falls back to identifier and filename heuristics only
- `--variant` lets you target a specific repo variant, especially GGUF quant variants like `Q4_K_M`
- initial GGUF support uses llama.cpp and is currently text-only

Then:

```bash
./esh model list
./esh model inspect mlx-community--qwen2.5-0.5b-instruct-4bit
```

Remove a model:

```bash
./esh model remove mlx-community--qwen2.5-0.5b-instruct-4bit
```

## 4. Chat in the Terminal

Start a chat:

```bash
./esh chat
```

Or open the launcher menu:

```bash
./esh
```

and select `1. Chat`.

Start a named chat:

```bash
./esh chat default
./esh chat product-notes
./esh chat benchmark-run
./esh chat benchmark-run --model mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

What the TUI shows:
- conversation transcript
- input line
- live footer with backend/model/cache/session stats

Example prompts:

```text
hello how are you, what can you do?
what is the name of Apple's CEO?
explain what a cache snapshot is in one paragraph
```

## 5. Work with Sessions

### From the CLI

List sessions:

```bash
./esh session list
```

Example output:

```text
2AB2CAF3-928F-4677-9DF9-E6693EEEDE08	demo-session	2 messages
8C56AF77-6256-4C9C-B428-7114FE03DA7C	default	2 messages
D59E570E-8F33-4547-8A02-F4F73B34478B	lifecycle	2 messages
```

Show one session:

```bash
./esh session show D59E570E-8F33-4547-8A02-F4F73B34478B
./esh session show model-flag-smoke
./esh session grep hello
```

### From inside chat

Open the session list:

```text
/sessions
```

Create a new session:

```text
/new
/new release-notes
```

Switch to another session:

```text
/switch default
/switch lifecycle
/switch D59E570E-8F33-4547-8A02-F4F73B34478B
```

Enable autosave:

```text
/autosave on
```

Manual save:

```text
/save
```

## 6. Use the In-Chat Command Menu

Open the command menu:

```text
/menu
```

Available TUI commands:

```text
/menu
/help
/close
/save
/autosave on
/autosave off
/autosave toggle
/new [name]
/switch <name-or-uuid>
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
/exit
```

Typical flow:

```text
/menu
/sessions
/model current
/search hello
/close
/new scratch
/autosave on
```

## 7. Build and Reuse Cache Artifacts

Cache artifacts are built from saved sessions.

### Step 1: find the session id

```bash
./esh session list
```

### Step 2: build raw and TurboQuant caches

```bash
./esh cache build --session D59E570E-8F33-4547-8A02-F4F73B34478B --mode raw
./esh cache build --session model-flag-smoke --mode turbo --model mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

### Step 3: inspect saved artifacts

```bash
./esh cache inspect
./esh cache inspect C46B9A7C-0636-4111-B300-C5A9AE1341C1
```

### Step 4: resume from a saved cache

```bash
./esh cache load --artifact C46B9A7C-0636-4111-B300-C5A9AE1341C1 --message "Continue this chat"
```

## 8. Benchmark Raw vs TurboQuant

Run a benchmark on a saved session:

```bash
./esh benchmark --session model-flag-smoke --model mlx-community/Qwen2.5-0.5B-Instruct-4bit --message "Continue with one short sentence about local AI."
```

Show saved benchmark history:

```bash
./esh benchmark history
```

## 9. Example End-to-End Flow

This is a realistic local workflow:

```bash
./scripts/bootstrap.sh
./esh doctor
./esh model install mlx-community/Qwen2.5-0.5B-Instruct-4bit
./esh chat default
```

Inside chat:

```text
hello how are you, what can you do?
/autosave on
/new planning
give me 3 name ideas for a local AI tool
/save
/exit
```

Back in CLI:

```bash
./esh session list
./esh cache build --session <planning-session-uuid> --mode turbo
./esh benchmark --session <planning-session-uuid>
./esh cache inspect
```

## 10. Health Checks and Troubleshooting

Basic environment check:

```bash
./esh doctor
```

Runtime validation script:

```bash
./scripts/verify-env.sh
```

`verify-env.sh` prints the resolved runtime layout. Use `./esh doctor` when you also want the Python MLX bridge imports checked.

If chat does not start:
- run `./esh doctor`
- make sure at least one model is installed
- check that `mlx`, `mlx-lm`, and `mlx-vlm` are reported

If model commands show nothing after a rename/update:
- Esh now stores data in `~/.esh`
- legacy `~/.llmcache` data is migrated automatically when possible

If you want a custom storage location:

```bash
ESH_HOME=/path/to/esh-home ./esh chat
```

## 11. Release Versioning

Esh keeps its release version in:
- `VERSION`
- `CHANGELOG.md`

Useful commands:

```bash
./scripts/release-version.sh show
./scripts/release-version.sh tag
./scripts/release-version.sh verify-tag v0.1.0
```

Suggested release flow:

```bash
git tag "$(./scripts/release-version.sh tag)"
git push origin "$(./scripts/release-version.sh tag)"
```

## 12. Known Current Limitations

These are intentional current boundaries, not hidden bugs:

- interactive install directly from search results is not built yet
- cache artifacts are not portable across different runtimes/models
- TUI transcript capture in logs will show ANSI redraw codes because it is a real terminal UI

## 13. Good First Use Cases

Esh is already useful for:
- local personal assistant chat
- benchmark and cache experiments on Apple Silicon
- testing session resume behavior
- comparing raw vs TurboQuant cache artifacts
- building a terminal-first local AI workflow before a desktop app exists
