# Validated model catalog

esh only offers models it has actually run. Engines that can run several concrete models (today, the
mlx_audio speech engines `mlx-speech-tts` and `mlx-speech-stt`) ship a **validated catalog**. It is produced
by a re-runnable harness and shown to consumers as per-model options with live, per-device readiness.

## Pieces

| Piece | Path |
| --- | --- |
| Harness | `scripts/model-catalog/validate.py` |
| Ranked candidates (inputs) | `scripts/model-catalog/candidates.json` |
| Shipped catalog (output, never hand-edited) | `Sources/EshMacCapabilities/Resources/catalog/validated-models.json` |
| Loader + readiness | `Sources/EshMacCapabilities/ValidatedModelCatalog.swift` |
| Public types | `Sources/EshCore/Runtime/CapabilityModelOption.swift` |
| Live smoke (dev/CI) | `scripts/smoke-mlx-speech.sh`, `.github/workflows/mlx-speech-smoke.yml` |

## Re-running the harness

```bash
# one-time: a production-shaped venv on internal APFS (exFAT breaks pip), engine base deps only
/opt/homebrew/bin/python3.11 -m venv ~/.esh/validation/venv
~/.esh/validation/venv/bin/python -m pip install numpy mlx mlx-lm "mlx-audio>=0.6.5,<0.7" \
  "misaki>=0.9.4" espeakng-loader phonemizer-fork num2words "spacy>=3.8,<3.9" \
  "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

~/.esh/validation/venv/bin/python scripts/model-catalog/validate.py --auto-deps        # whole shortlist
~/.esh/validation/venv/bin/python scripts/model-catalog/validate.py --only mlx-community/csm-1b-8bit --force
```

For each candidate the harness does the following:

1. **Provision.** It installs the declared `extraPackages`. With `--auto-deps`, a `No module named 'X'`
   failure installs X, records it and retries.
2. **Load and run.** It runs one tiny real job through the same bridge command the host runs, under
   `/usr/bin/time -l`, which gives the peak memory footprint.
3. **Check.** TTS output is round-tripped through Parakeet (word overlap ≥ 0.6). STT runs against a
   deterministic macOS `say` fixture.
4. **Record.** The entry stores status, size on Hugging Face, bytes actually downloaded (including
   auxiliary repos), peak memory, the recommended Mac memory tier, known-good required arguments, the
   license and commercial-use flag, the sample check, cold and warm timings, and a validation stamp
   (date, machine, mlx-audio, mlx and Python versions).

The harness is idempotent. An entry already validated against the same mlx-audio version is skipped unless
`--force` is given. It saves after every model, so an interrupted pass resumes. Weights go to the
configured assets volume (`~/.esh/storage.json`) in the same HF cache layout the host uses, so the app
reuses them.

`status` takes one of these values:

- `ok`: ran, and its output passed the check.
- `needs-deps`: a module couldn't be resolved.
- `failed`: crashed, produced bad output, or needs a gated repo.
- `unsupported`: the runtime doesn't implement the architecture.

## Consumer API (Esh Studio)

Static facts are on the descriptor, as `CapabilityProviderDescriptor.modelOptions: [CapabilityModelOption]`.
Live state comes from one call:

```swift
let rows = await runtime.modelOptions(for: .audioSynthesizeSpeech)   // [ModelOptionAvailability]
for row in rows {
    row.option.displayName      // "Kokoro 82M"
    row.option.isRunnable       // false for failed/unsupported/needs-deps (still listed, with the reason)
    row.readiness               // .ready | .needsSetup(reason) | .downloadRequired(bytes)
                                // | .unsupportedOnThisMachine(reason) | .notValidated(reason) | .unsupportedOnPlatform
    row.fit                     // .comfortable | .tight | .exceeds | .unknown  (observed peak vs this Mac's RAM)
    row.sizeBytes               // bytes still to download, else on-disk size
    row.note                    // "Download 355 MB · fits comfortably"
}
// run one:
ExecutionRequest(capability: .audioSynthesizeSpeech, inputs: [.text("Hi")], output: OutputSpec(modality: .audio),
                 options: ExecutionOptions(["model": .string(row.option.id)]),
                 model: row.providerID)                                   // pin the mlx engine (Apple stays Auto default)
```

Knobs a model requires, such as Kokoro's `voice`, are filled in from `option.defaultOptions` when the caller
leaves them unset, and the caller's explicit options always win. Call `refreshCapabilityAvailability()`
after an install so the engine-level state is current, then call `modelOptions(for:)` again.
