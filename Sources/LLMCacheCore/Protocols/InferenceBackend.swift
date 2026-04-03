import Foundation

public protocol InferenceBackend: Sendable {
    var kind: BackendKind { get }
    var runtimeVersion: String { get }

    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking
}
