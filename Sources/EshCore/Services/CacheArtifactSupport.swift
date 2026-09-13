import Foundation

/// Portable seam for the macOS-only turbo (TurboQuant) prompt-cache compressor (M9).
///
/// `TurboQuantCompressor` drives the TurboQuant bridge (a subprocess) and is macOS-only, so it lives in
/// `EshMacRuntime`. Portable `ExternalInferenceService` selects a `CacheCompressor` for a stored cache
/// artifact by cache mode; for `.turbo` it consults this hook. `EshMacRuntime.MacRuntimeBootstrap.install()`
/// sets the factory; when unset (iOS, or before bootstrap) turbo falls back to passthrough. Prompt-cache
/// artifacts are an MLX-runtime concept and `.mlx` installs never exist on iOS, so the fallback is never a
/// user-reachable inference path there.
///
/// Set once during process bootstrap, before concurrent inference begins — hence `nonisolated(unsafe)`.
public enum CacheArtifactSupport {
    public nonisolated(unsafe) static var turboCompressorFactory: (@Sendable () -> any CacheCompressor)?
}
