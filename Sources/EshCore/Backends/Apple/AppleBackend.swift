import Foundation

/// Reserved model identifiers that route to the Apple Foundation Models on-device provider. An
/// explicit downloaded-model request never matches these, so Apple is never silently substituted.
public enum AppleProvider {
    public static let reservedModelIDs: Set<String> = ["apple", "apple-intelligence", "apple-foundation"]
    public static let canonicalModelID = "apple-intelligence"

    public static func isAppleModelID(_ id: String?) -> Bool {
        guard let id = id?.lowercased() else { return false }
        return reservedModelIDs.contains(id)
    }

    /// A synthetic install representing the Apple on-device system model (no download, no files).
    public static func syntheticInstall() -> ModelInstall {
        ModelInstall(
            id: canonicalModelID,
            spec: ModelSpec(
                id: canonicalModelID,
                displayName: "Apple Intelligence (on-device)",
                backend: .apple,
                source: ModelSource(kind: .localPath, reference: "apple.foundation-models")
            ),
            installPath: "",
            sizeBytes: 0,
            backendFormat: "apple-foundation-models",
            runtimeVersion: "apple-foundation-models"
        )
    }
}

/// Apple Foundation Models as a first-class inference backend. Execution is strictly on-device
/// (`SystemLanguageModel.default`); esh never invokes any Private Cloud Compute / cloud path, so a
/// `localOnly` request can never be routed off-device here. Generation fails loudly when Apple is
/// unavailable rather than silently degrading.
public struct AppleBackend: InferenceBackend, Sendable {
    public let kind: BackendKind = .apple
    public let runtimeVersion: String = "apple-foundation-models"

    public init() {}

    public func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        AppleBackendRuntime(modelID: install.id)
    }

    public func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        let status = AppleIntelligenceService().status()
        if status.available {
            return BackendCapabilityReport(
                backend: kind, runtimeVersion: runtimeVersion, ready: true,
                supportedFeatures: [.directInference]
            )
        }
        return BackendCapabilityReport(
            backend: kind, runtimeVersion: runtimeVersion, ready: false,
            supportedFeatures: [],
            unavailableFeatures: [.init(feature: .directInference, reason: status.detail)],
            warnings: [status.detail]
        )
    }

    public func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking {
        AppleCompatibilityChecker()
    }
}

private struct AppleCompatibilityChecker: CompatibilityChecking, Sendable {
    func validate(manifest: CacheManifest) throws {
        throw CompatibilityIssue(reason: "Apple Foundation Models does not support prompt caches.")
    }
}

/// A `BackendRuntime` over the Apple on-device system model. Non-streamed (Apple's response is
/// returned whole here); emitted as a single chunk, honestly reflected in capability resolution.
public final class AppleBackendRuntime: BackendRuntime, @unchecked Sendable {
    public let backend: BackendKind = .apple
    public let modelID: String
    private var currentMetrics: Metrics

    init(modelID: String, metrics: Metrics = .init()) {
        self.modelID = modelID
        self.currentMetrics = metrics
    }

    public var metrics: Metrics { currentMetrics }

    public func prepare(session: ChatSession) async throws {}

    public func generate(
        session: ChatSession,
        config: GenerationConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let normalized = PromptSessionNormalizer().normalized(session: session)
                    let instructions = normalized.messages
                        .filter { $0.role == .system }
                        .map(\.text).joined(separator: "\n")
                    let conversation = normalized.messages
                        .filter { $0.role != .system }
                        .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
                        .joined(separator: "\n")
                    let start = ContinuousClock.now
                    let text = try await AppleIntelligenceService().generate(
                        prompt: conversation.isEmpty ? " " : conversation,
                        instructions: instructions.isEmpty ? nil : instructions
                    )
                    let elapsed = start.duration(to: .now)
                    let ms = Double(elapsed.components.seconds) * 1000
                        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                    self.currentMetrics = Metrics(ttftMilliseconds: ms, finishReason: "stop")
                    if !text.isEmpty { continuation.yield(text) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func exportRuntimeCache() async throws -> CacheSnapshot {
        throw StoreError.invalidManifest("Apple Foundation Models does not support cache export.")
    }
    public func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {
        throw StoreError.invalidManifest("Apple Foundation Models does not support cache import.")
    }
    public func validateCacheCompatibility(_ manifest: CacheManifest) async throws {
        throw CompatibilityIssue(reason: "Apple Foundation Models does not support prompt caches.")
    }
    public func unload() async {}
}
