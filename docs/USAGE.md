# Esh Usage Guide

This guide explains how to use Esh in day-to-day work.

## 1. Install and Run

### Dev mode

```bash
./scripts/bootstrap.sh
./esh doctor
./esh chat
```

What bootstrap does:
- creates or updates the local `.venv`
- installs pinned Python bridge dependencies
- builds the Swift CLI
- prepares the local runtime

### Release mode

```bash
./scripts/package-release.sh
./dist/esh-macos-<version>/esh doctor
./dist/esh-macos-<version>/esh chat
```

The packaged release includes:
- `esh` launcher
- `bin/esh`
- embedded `python/`
- bridge scripts
- pinned Python dependencies

## 2. Understand the Command Surface

Main commands:

```text
esh chat [session-name]
esh doctor
esh model list
esh model install <hf-repo-id>
esh model inspect <model-id>
esh model remove <model-id>
esh session list
esh session show <uuid>
esh cache build --session <uuid> [--mode raw|turbo] [--model <id>]
esh cache load --artifact <uuid> --message <text> [--model <id>]
esh cache inspect [artifact-uuid]
```

## 3. Find and Install Models

Esh does not yet search Hugging Face for you.

Current model workflow:
1. Find an MLX-compatible repo on Hugging Face.
2. Copy its repo id.
3. Install it with Esh.

Example:

```bash
./esh model install mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

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

Start a named chat:

```bash
./esh chat default
./esh chat product-notes
./esh chat benchmark-run
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
/sessions
/caches
/doctor
/model inspect <id>
/session show <uuid>
/cache inspect <uuid>
/exit
```

Typical flow:

```text
/menu
/sessions
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
./esh cache build --session D59E570E-8F33-4547-8A02-F4F73B34478B --mode turbo
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

## 8. Example End-to-End Flow

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
./esh cache inspect
```

## 9. Health Checks and Troubleshooting

Basic environment check:

```bash
./esh doctor
```

Runtime validation script:

```bash
./scripts/verify-env.sh
```

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

## 10. Known Current Limitations

These are intentional current boundaries, not hidden bugs:

- no built-in Hugging Face search yet
- no explicit polished `chat --model <id>` selector yet
- some CLI commands still expect UUIDs rather than human names
- cache artifacts are not portable across different runtimes/models
- TUI transcript capture in logs will show ANSI redraw codes because it is a real terminal UI

## 11. Good First Use Cases

Esh is already useful for:
- local personal assistant chat
- benchmark and cache experiments on Apple Silicon
- testing session resume behavior
- comparing raw vs TurboQuant cache artifacts
- building a terminal-first local AI workflow before a desktop app exists
