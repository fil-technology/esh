#if !os(macOS)
import Foundation
import EshCore

/// iOS/visionOS/tvOS stand-in for the macOS MLX text backend, so cross-platform host code that registers
/// `MLXBackend(persistent: true)` still compiles. It never loads anything: MLX text inference here runs through a
/// Python worker process, which these platforms do not allow. Behavior comes from `UnsupportedPlatformBackend`
/// (EshCore, tested on macOS): not ready, no supported features, every feature explicitly unavailable; Auto never
/// selects it; `EshRuntime` refuses a pinned MLX model with `EshRuntimeError.backendUnavailable(.mlx, …)`;
/// `loadRuntime` throws `BackendUnsupportedOnPlatformError`. On iOS, run downloaded models with the embedded GGUF
/// backend (`EshLlamaCpp`) or use Apple Foundation Models.
public struct MLXBackend: InferenceBackend, BackendLifecycleDescribing, PlatformUnsupportedBackend, Sendable {
    public static let unavailableReason =
        "MLX text models run through a Python worker process, which is macOS-only. On iOS use an embedded GGUF model (EshLlamaCpp) or Apple Foundation Models."

    private let base = UnsupportedPlatformBackend(kind: .mlx, reason: MLXBackend.unavailableReason)

    public init(persistent: Bool = false) { _ = persistent }

    public var kind: BackendKind { base.kind }
    public var runtimeVersion: String { base.runtimeVersion }
    public var unsupportedPlatformReason: String { base.reason }
    public var lifecycleTraits: BackendLifecycleTraits { base.lifecycleTraits }
    public func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport { base.capabilityReport(for: install) }
    public func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime { try await base.loadRuntime(for: install) }
    public func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { base.makeCompatibilityChecker(for: install) }
}
#endif
