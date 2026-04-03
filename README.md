# Esh

Local LLM chat and cache tooling for Apple Silicon, built in Swift with an MLX-backed Python bridge.

## Quick Start

### Dev mode

Bootstrap once:

```bash
./scripts/bootstrap.sh
```

Then run the tool with the project launcher:

```bash
./esh doctor
./esh model list
./esh chat
```

### Install the small Qwen model used in testing

```bash
./esh model install mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

List installed models:

```bash
./esh model list
```

Inspect the model:

```bash
./esh model inspect mlx-community--qwen2.5-0.5b-instruct-4bit
```

### Chat with that model

`esh chat` currently loads the first installed model. If the Qwen model above is the one you installed, you can just run:

```bash
./esh chat
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
./esh session list
./esh cache build --session <session-uuid> --mode raw
./esh cache build --session <session-uuid> --mode turbo
./esh cache inspect <artifact-uuid>
./esh cache load --artifact <artifact-uuid> --message "Continue this chat"
```

## Release packaging

Build a self-contained release artifact:

```bash
./scripts/package-release.sh
```

That creates a bundle under `dist/` containing:

- `esh` launcher
- `bin/esh` release binary
- embedded `python/`
- packaged bridge files under `share/esh/`

Run the packaged tool:

```bash
./dist/esh-macos-<version>/esh doctor
./dist/esh-macos-<version>/esh chat
```

## Data location

By default, models, sessions, and caches live under:

```text
~/.esh
```

You can override that with:

```bash
ESH_HOME=/path/to/custom-root ./esh chat
```
