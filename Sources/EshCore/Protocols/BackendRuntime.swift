import Foundation

public struct GenerationConfig: Codable, Hashable, Sendable {
    public var maxTokens: Int
    public var temperature: Double

    public init(maxTokens: Int = 512, temperature: Double = 0.7) {
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public protocol BackendRuntime: Sendable {
    var backend: BackendKind { get }
    var modelID: String { get }
    var metrics: Metrics { get async }

    func prepare(session: ChatSession) async throws
    func generate(
        session: ChatSession,
        config: GenerationConfig
    ) -> AsyncThrowingStream<String, Error>

    func exportRuntimeCache() async throws -> CacheSnapshot
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws
    func unload() async
}
