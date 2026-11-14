import Foundation

/// A model load refused by the live memory-safety gate. Carries a human-readable reason; callers that own a
/// typed error surface (e.g. `EshRuntimeError.insufficientMemory`) map it.
public struct ModelLoadRefused: LocalizedError, Equatable, Sendable {
    public let modelID: String
    public let reason: String
    public init(modelID: String, reason: String) { self.modelID = modelID; self.reason = reason }
    public var errorDescription: String? { "Not loading \(modelID): \(reason)" }
}

/// The ONE live, load-time memory-safety gate for every esh model-loading path (SDK facade, CLI commands,
/// `esh serve`'s warm pool, chat/TUI, agent, cache tools). Before 2026-11 only `EshRuntime` (the SDK facade)
/// ran `MemorySafetyPreflight`; the CLI and server loaded through the pool's size estimate alone.
///
/// Sizing is the facade's: the catalog's MEASURED peak when known, else the larger of the catalog estimate and
/// the on-disk weight size (+5%), plus any caller-known extra (e.g. resident KV caches). Small models are never
/// gated (`MemorySafetyPreflight.smallModelFloorGB`), so lightweight flows are unaffected.
public enum ModelLoadSafetyGate {
    public static func requiredPeakGB(for install: ModelInstall, additionalGB: Double = 0) -> Double {
        let gb = 1_073_741_824.0
        let catalog = RecommendedModelRegistry().resolve(alias: install.id)
        let diskProxyGB = Double(install.sizeBytes) / gb * 1.05
        let base = catalog?.measuredPeakMemoryGB ?? max(catalog?.estimatedMemoryGB ?? 0, diskProxyGB)
        return base + max(0, additionalGB)
    }

    /// Pure verdict against a given host snapshot (unit-testable).
    public static func verdict(for install: ModelInstall, additionalGB: Double = 0, host: HostResources) -> ResourceFitVerdict {
        MemorySafetyPreflight.evaluate(requiredPeakGB: requiredPeakGB(for: install, additionalGB: additionalGB), host: host)
    }

    /// Live check: throws `ModelLoadRefused` when loading `install` right now is unsafe.
    public static func check(_ install: ModelInstall, root: PersistenceRoot = .default(), additionalGB: Double = 0) throws {
        let required = requiredPeakGB(for: install, additionalGB: additionalGB)
        guard required >= MemorySafetyPreflight.smallModelFloorGB else { return }   // skip the probe for small models
        let host = HostResourceProbe.snapshot(root: root)
        if case let .gated(reason, _, _) = MemorySafetyPreflight.evaluate(requiredPeakGB: required, host: host) {
            throw ModelLoadRefused(modelID: install.id, reason: reason)
        }
    }
}

public extension InferenceBackend {
    /// Load a runtime through the live memory-safety gate. Every esh loading path should use this instead of
    /// calling `loadRuntime(for:)` directly, so a heavy model fails safely with a reason instead of driving the
    /// machine into swap.
    func loadRuntimeGuarded(for install: ModelInstall, root: PersistenceRoot = .default()) async throws -> BackendRuntime {
        try ModelLoadSafetyGate.check(install, root: root)
        return try await loadRuntime(for: install)
    }
}
