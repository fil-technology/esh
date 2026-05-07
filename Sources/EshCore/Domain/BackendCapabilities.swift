import Foundation

public enum BackendRuntimeFeature: String, Codable, Hashable, Sendable, CaseIterable {
    case directInference = "direct-inference"
    case tokenStreaming = "token-streaming"
    case promptCacheBuild = "prompt-cache-build"
    case promptCacheLoad = "prompt-cache-load"
    case promptCacheBenchmark = "prompt-cache-benchmark"
    case toolMessages = "tool-messages"
    case multimodalInput = "multimodal-input"
    case thinkingMode = "thinking-mode"
    case kvCacheQuantization = "kv-cache-quantization"
    case responseFormatJsonSchema = "response-format-json-schema"
}

public struct UnavailableBackendFeature: Codable, Hashable, Sendable {
    public var feature: BackendRuntimeFeature
    public var reason: String

    public init(feature: BackendRuntimeFeature, reason: String) {
        self.feature = feature
        self.reason = reason
    }
}

public struct BackendCapabilityReport: Codable, Hashable, Sendable {
    public var backend: BackendKind
    public var runtimeVersion: String
    public var ready: Bool
    public var supportedFeatures: [BackendRuntimeFeature]
    public var unavailableFeatures: [UnavailableBackendFeature]
    public var warnings: [String]

    public init(
        backend: BackendKind,
        runtimeVersion: String,
        ready: Bool,
        supportedFeatures: [BackendRuntimeFeature],
        unavailableFeatures: [UnavailableBackendFeature] = [],
        warnings: [String] = []
    ) {
        self.backend = backend
        self.runtimeVersion = runtimeVersion
        self.ready = ready
        self.supportedFeatures = orderedUnique(supportedFeatures)
        self.unavailableFeatures = unavailableFeatures
        self.warnings = orderedUnique(warnings)
    }

    public func supports(_ feature: BackendRuntimeFeature) -> Bool {
        supportedFeatures.contains(feature)
    }

    public func unavailableFeature(_ feature: BackendRuntimeFeature) -> UnavailableBackendFeature? {
        unavailableFeatures.first { $0.feature == feature }
    }
}

private func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen: Set<T> = []
    return values.filter { seen.insert($0).inserted }
}
