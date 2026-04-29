# Esh Orchestrator Roadmap

Esh is moving toward a macOS-focused local model orchestrator. It should manage,
validate, select, and route existing runtimes instead of implementing tensor
kernels, attention, KV cache internals, quantization algorithms, tokenizers, or
model architectures itself.

## Current Required Engines

### llama.cpp

Purpose:
- GGUF model execution
- broad quantized model compatibility
- CPU and Metal acceleration on macOS

Esh detects `llama-cli` passively from `ESH_LLAMA_CPP_CLI`,
`LLAMA_CPP_CLI`, Homebrew paths, or `PATH`. Detection does not install
anything automatically.

### MLX / mlx-lm

Purpose:
- Apple Silicon-native inference
- MLX/Hugging Face model directories
- local text generation through the Python bridge

Esh validates the packaged Python bridge and MLX packages through `esh doctor`
and `esh engines doctor mlx`.

## Configuration

Esh reads `~/.esh/config.toml` when present. Create or inspect the file with:

```bash
esh config init
esh config show
esh config path
```

Default config:

```toml
[defaults]
engine = "auto"
model_dir = "~/.esh/models"
context_size = 8192

[engines.llama_cpp]
enabled = true
binary = "auto"
metal = true

[engines.mlx]
enabled = true
python = "auto"

[experimental]
ollama_adapter = false
llamafile = false
transformers = false
llama_cpp_server = false
```

## Implemented Orchestration Surface

```bash
esh doctor
esh engines list
esh engines doctor llama.cpp
esh engines doctor mlx
esh config show
esh validate <model>
esh validate <model> --engine llama.cpp
esh validate <model> --engine mlx --json
```

`esh validate` inspects local model files, detects GGUF or MLX format, reports
compatible engines, selects a ready runtime when possible, and prints missing
dependencies with suggested fixes.

## Optional Future Engines

These are tracked in `esh engines list` as optional roadmap adapters. They are
not required for core Esh usage and are disabled by default until enabled in
`~/.esh/config.toml`.

- `llamafile`: portable single-file model execution for demos and simple sharing.
- `Ollama`: adapter for users who already have Ollama models installed.
- `Transformers` / PyTorch: heavy experimental fallback for safetensors models.
- `llama.cpp server`: managed `llama-server` detection for future server routing.

Current optional-engine support is intentionally detection and configuration
only. Esh reports installed binaries and configuration status without routing
inference through those optional engines yet.

## Non-Goals

Esh should not implement a custom inference engine at this stage. Keep tool use,
structured output, chat templates, local API routing, and benchmarking above the
engine layer.
