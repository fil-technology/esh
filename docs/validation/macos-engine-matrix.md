# macOS Engine Validation Matrix

| Engine | Model Format | Apple Silicon | Intel Mac | Status | Notes |
|---|---|---:|---:|---|---|
| llama.cpp | GGUF | Yes | Yes | Required | Metal expected on Apple Silicon when the installed binary supports it. |
| MLX / mlx-lm | MLX | Yes | No | Required | Requires Apple Silicon and a healthy Python bridge environment. |
| Ollama | Managed | Yes | Yes | Optional disabled by default | Enable with `[experimental] ollama_adapter = true`; adapter routing remains future work. |
| llamafile | Executable | Yes | Yes | Optional disabled by default | Enable with `[experimental] llamafile = true`; portable runtime routing remains future work. |
| Transformers / PyTorch | safetensors | Partial | Partial | Experimental disabled by default | Enable with `[experimental] transformers = true`; heavy fallback remains non-default. |
| llama.cpp server | GGUF HTTP | Yes | Yes | Optional disabled by default | Enable detection with `[experimental] llama_cpp_server = true`; managed server routing remains future work. |

## Manual Checks

```bash
esh doctor
esh engines list
esh engines doctor llama.cpp
esh engines doctor mlx
esh config show
esh validate <installed-model-id>
```

Expected result:
- at least one required text engine reports `ready`
- GGUF installs select `llama.cpp`
- MLX installs select `MLX` on Apple Silicon
- missing engines include an actionable install or setup hint
