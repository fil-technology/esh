import Foundation

/// Optimization schema version. Bump when strategy identities/semantics change so persisted
/// benchmark evidence and execution profiles can be invalidated deterministically.
public enum OptimizationSchema {
    public static let version = 1
}

/// User-facing performance preference. `auto` is evidence-driven; the others are explicit user
/// preferences that still respect minimum quality/stability constraints.
public enum PerformanceMode: String, Codable, Sendable, CaseIterable {
    case auto
    case speed
    case balanced
    case memory

    public init?(cliValue: String) {
        self.init(rawValue: cliValue.lowercased())
    }
}

/// Families of optimization. New categories can be added without changing the public request model.
public enum OptimizationCategory: String, Codable, Sendable, CaseIterable {
    case kvCache = "kv-cache"
    case promptCache = "prompt-cache"
    case speculativeDecoding = "speculative-decoding"
    case contextPolicy = "context-policy"
    case quantization
    case batchingPrefill = "batching-prefill"
    case backendTuning = "backend-tuning"
}

/// Workload shapes that can have materially different optimal strategies.
public enum OptimizationWorkload: String, Codable, Sendable, CaseIterable {
    case chat
    case coding
    case reasoning
    case structured
    case agentPrefix = "agent-prefix"
    case longContext = "long-context"

    public init?(cliValue: String) {
        switch cliValue.lowercased() {
        case "chat", "general": self = .chat
        case "coding", "code": self = .coding
        case "reasoning", "reason": self = .reasoning
        case "structured", "tools", "tool": self = .structured
        case "agent", "agent-prefix", "prefix": self = .agentPrefix
        case "long", "long-context", "longcontext": self = .longContext
        default: return nil
        }
    }
}

/// Bucketed context ranges so benchmark evidence generalizes without over-keying on exact tokens.
public enum ContextBucket: String, Codable, Sendable, CaseIterable {
    case short   // <= ~2k
    case medium  // <= ~6k
    case long    // <= ~12k
    case xlong   // <= ~24k
    case xxlong  // > ~24k

    public init(tokens: Int) {
        switch tokens {
        case ..<2049: self = .short
        case ..<6145: self = .medium
        case ..<12289: self = .long
        case ..<24577: self = .xlong
        default: self = .xxlong
        }
    }
}

/// A single optimization option, declaring what it is and the constraints under which it applies.
/// Strategies are data: a future technique is added by registering another value, not by editing
/// core inference orchestration.
public struct OptimizationStrategy: Codable, Hashable, Sendable, Identifiable {
    public var id: String                       // stable id, e.g. "kv.turbo", "prompt.reuse"
    public var category: OptimizationCategory
    public var displayName: String
    public var summary: String
    public var backends: [BackendKind]          // supported backends
    public var modelFamilies: [String]?         // nil = any family
    public var minRuntimeVersion: String?       // nil = any
    /// Output distribution can change relative to the category baseline (needs quality validation).
    public var qualityMayChange: Bool
    /// Outputs are expected bit-identical to the baseline (safe to auto-enable without quality runs).
    public var distributionEquivalent: Bool
    /// Approximate memory delta vs baseline for this category (negative = saves memory). nil = unknown.
    public var estimatedMemoryDeltaRatio: Double?
    /// Must have local measured evidence before `auto` may select it.
    public var requiresBenchmarkBeforeAuto: Bool
    /// The known-good default for its category (conservative fallback).
    public var isBaseline: Bool
    public var experimental: Bool
    public var parameters: [String: String]

    public init(
        id: String,
        category: OptimizationCategory,
        displayName: String,
        summary: String,
        backends: [BackendKind],
        modelFamilies: [String]? = nil,
        minRuntimeVersion: String? = nil,
        qualityMayChange: Bool = false,
        distributionEquivalent: Bool = false,
        estimatedMemoryDeltaRatio: Double? = nil,
        requiresBenchmarkBeforeAuto: Bool = false,
        isBaseline: Bool = false,
        experimental: Bool = false,
        parameters: [String: String] = [:]
    ) {
        self.id = id
        self.category = category
        self.displayName = displayName
        self.summary = summary
        self.backends = backends
        self.modelFamilies = modelFamilies
        self.minRuntimeVersion = minRuntimeVersion
        self.qualityMayChange = qualityMayChange
        self.distributionEquivalent = distributionEquivalent
        self.estimatedMemoryDeltaRatio = estimatedMemoryDeltaRatio
        self.requiresBenchmarkBeforeAuto = requiresBenchmarkBeforeAuto
        self.isBaseline = isBaseline
        self.experimental = experimental
        self.parameters = parameters
    }
}

/// The (backend, model, runtime, hardware) context a strategy is evaluated against.
public struct OptimizationContext: Sendable, Equatable {
    public var backend: BackendKind
    public var modelID: String
    public var modelFamily: String?
    public var runtimeVersion: String?
    public var host: HostMachineProfile?

    public init(
        backend: BackendKind,
        modelID: String,
        modelFamily: String? = nil,
        runtimeVersion: String? = nil,
        host: HostMachineProfile? = nil
    ) {
        self.backend = backend
        self.modelID = modelID
        self.modelFamily = modelFamily
        self.runtimeVersion = runtimeVersion
        self.host = host
    }
}

public enum OptimizationCompatibility: Sendable, Equatable {
    case compatible
    case incompatible(reason: String)

    public var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }
}
