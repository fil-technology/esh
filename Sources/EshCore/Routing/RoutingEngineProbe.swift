import Foundation

/// Portable seam for detecting installed optional generative engines during routing (M9).
///
/// The optional generative-engine runtime (`GenerativeEngineManager`, which installs/queries local Python
/// engines) is macOS-only and lives in `EshMacRuntime`. Portable routing (`IntentResolver`) must not
/// reference it, so it consults this hook instead. `EshMacRuntime` installs the real probe at startup
/// (`MacRuntimeBootstrap.install()`); on iOS, or before install, the hook is `nil` and engines report
/// "not installed" (no such engine exists there). Callers may still override per-call via
/// `IntentResolver.resolve(engineInstalled:)`.
///
/// Set exactly once during process bootstrap, before concurrent routing begins — hence `nonisolated(unsafe)`.
public enum RoutingEngineProbe {
    public nonisolated(unsafe) static var isInstalled: (@Sendable (GenerativeEngineID, PersistenceRoot) -> Bool)?
}
