import Foundation

public struct BenchmarkResult: Sendable {
    public var rawArtifactBytes: Int64
    public var turboArtifactBytes: Int64
    public var rawCompressionRatio: Double
    public var turboCompressionRatio: Double

    public init(
        rawArtifactBytes: Int64,
        turboArtifactBytes: Int64,
        rawCompressionRatio: Double,
        turboCompressionRatio: Double
    ) {
        self.rawArtifactBytes = rawArtifactBytes
        self.turboArtifactBytes = turboArtifactBytes
        self.rawCompressionRatio = rawCompressionRatio
        self.turboCompressionRatio = turboCompressionRatio
    }
}

public struct BenchmarkService: Sendable {
    private let cacheService: CacheService

    public init(cacheService: CacheService) {
        self.cacheService = cacheService
    }

    public func compare(
        runtime: BackendRuntime,
        session: ChatSession,
        install: ModelInstall,
        codec: CacheSnapshotCodec,
        turbo: CacheCompressor
    ) async throws -> BenchmarkResult {
        let raw = try await cacheService.buildArtifact(
            runtime: runtime,
            session: session,
            install: install,
            codec: codec,
            compressor: PassthroughCompressor()
        )
        let compressed = try await cacheService.buildArtifact(
            runtime: runtime,
            session: session,
            install: install,
            codec: codec,
            compressor: turbo
        )
        return BenchmarkResult(
            rawArtifactBytes: raw.artifact.sizeBytes,
            turboArtifactBytes: compressed.artifact.sizeBytes,
            rawCompressionRatio: 1,
            turboCompressionRatio: raw.artifact.sizeBytes > 0
                ? Double(raw.artifact.sizeBytes) / Double(compressed.artifact.sizeBytes)
                : 1
        )
    }
}
