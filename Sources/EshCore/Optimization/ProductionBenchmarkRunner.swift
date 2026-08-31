import Foundation

/// Drives the real `ExternalInferenceService` — the SAME path the CLI and HTTP server use — so
/// benchmark numbers reflect production inference, not toy code. Metrics come straight from the
/// inference response; nothing is synthesized.
public struct ProductionBenchmarkRunner: BenchmarkInferenceRunner {
    private let service: ExternalInferenceService

    public init(service: ExternalInferenceService) {
        self.service = service
    }

    public init(root: PersistenceRoot = .default()) {
        self.service = ExternalInferenceService(
            modelStore: FileModelStore(root: root),
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root)
        )
    }

    public func generate(
        model: String,
        backend: BackendKind,
        cacheMode: CacheMode,
        prompt: String,
        maxTokens: Int,
        seed: Int?
    ) async throws -> BenchmarkRunOutput {
        let generation = GenerationConfig(
            maxTokens: maxTokens,
            temperature: 0.0,
            seed: seed.map { UInt64(bitPattern: Int64($0)) }
        )
        let request = ExternalInferenceRequest(
            model: model,
            cacheMode: cacheMode,
            messages: [ExternalInferenceMessage(role: .user, text: prompt)],
            generation: generation
        )
        let response = try await service.infer(request: request)
        let metrics = response.metrics
        return BenchmarkRunOutput(
            outputText: response.outputText,
            ttftMs: metrics.ttftMilliseconds,
            decodeTokensPerSec: metrics.tokensPerSecond,
            prefillTokensPerSec: nil,
            endToEndMs: nil,
            tokensGenerated: metrics.contextTokens,
            memoryBytes: metrics.memoryBytes,
            kvCacheBytes: metrics.cacheSizeBytes
        )
    }
}
