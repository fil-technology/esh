import Foundation

public protocol InferenceBackend: Sendable {
    var kind: BackendKind { get }
    var runtimeVersion: String { get }

    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking
}

public extension InferenceBackend {
    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        _ = install
        return BackendCapabilityReport(
            backend: kind,
            runtimeVersion: runtimeVersion,
            ready: true,
            supportedFeatures: [.directInference]
        )
    }
}
