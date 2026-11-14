#if !os(macOS)
import Foundation
import EshCore

/// iOS/visionOS/tvOS stand-in for the macOS MLX text backend, so cross-platform host code that registers
/// `MLXBackend(persistent: true)` still compiles. It never loads anything: MLX text inference here runs through a
/// Python worker process, which these platforms do not allow. Its capability report says so explicitly, Auto
/// routing never selects it, and a pinned MLX model fails with a typed, explained error. On iOS, run downloaded
/// models with the embedded GGUF backend (`EshLlamaCpp`) or use Apple Foundation Models.
public struct MLXBackend: InferenceBackend, BackendLifecycleDescribing, Sendable {
    public let kind: BackendKind = .mlx
    public let runtimeVersion: String = "unavailable-on-this-platform"
    public static let unavailableReason =
        "MLX text models run through a Python worker process, which is macOS-only. On iOS use an embedded GGUF model (EshLlamaCpp) or Apple Foundation Models."

    public init(persistent: Bool = false) { _ = persistent }

    public func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(
            backend: kind, runtimeVersion: runtimeVersion, ready: false, supportedFeatures: [],
            unavailableFeatures: [.init(feature: .directInference, reason: Self.unavailableReason)],
            warnings: [Self.unavailableReason])
    }

    public func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        throw StoreError.invalidManifest(Self.unavailableReason)
    }

    public func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { Unavailable() }

    public var lifecycleTraits: BackendLifecycleTraits {
        BackendLifecycleTraits(residency: .handleCached, inProcess: false, prefixReuse: .none, serializesRequestsPerModel: true,
                               contextBoundedAtLoad: false, cancelsDuringPrefill: false, supportsIOS: false)
    }

    private struct Unavailable: CompatibilityChecking {
        func validate(manifest: CacheManifest) throws { throw CompatibilityIssue(reason: MLXBackend.unavailableReason) }
    }
}
#endif
