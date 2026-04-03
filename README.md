# llmcache

Local LLM chat and cache tooling for Apple Silicon, built in Swift with an MLX-backed Python bridge.

## Quick Start

### Dev mode

Bootstrap once:

```bash
./scripts/bootstrap.sh
```

Then run the tool with the project launcher:

```bash
./llmcache doctor
./llmcache model list
./llmcache chat
```

### Install the small Qwen model used in testing

```bash
./llmcache model install mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

List installed models:

```bash
./llmcache model list
```

Inspect the model:

```bash
./llmcache model inspect mlx-community--qwen2.5-0.5b-instruct-4bit
```

### Chat with that model

`llmcache chat` currently loads the first installed model. If the Qwen model above is the one you installed, you can just run:

```bash
./llmcache chat
```

Example session:

```text
> hello how are you, what can you do?
> what is the name of Apple's CEO?
> 1+1
> /save
> /exit
```

### Useful commands

```bash
./llmcache session list
./llmcache cache build --session <session-uuid> --mode raw
./llmcache cache build --session <session-uuid> --mode turbo
./llmcache cache inspect <artifact-uuid>
./llmcache cache load --artifact <artifact-uuid> --message "Continue this chat"
```

## Release packaging

Build a self-contained release artifact:

```bash
./scripts/package-release.sh
```

That creates a bundle under `dist/` containing:

- `llmcache` launcher
- `bin/llmcache` release binary
- embedded `python/`
- packaged bridge files under `share/llmcache/`

Run the packaged tool:

```bash
./dist/llmcache-macos-<version>/llmcache doctor
./dist/llmcache-macos-<version>/llmcache chat
```

## Data location

By default, models, sessions, and caches live under:

```text
~/.llmcache
```

You can override that with:

```bash
LLMCACHE_HOME=/path/to/custom-root ./llmcache chat
```
