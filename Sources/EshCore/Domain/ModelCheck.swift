import Foundation

public enum ModelCheckBackendPreference: String, Codable, Hashable, Sendable, CaseIterable {
    case auto
    case mlx
    case gguf

    public var resolvedBackend: BackendKind? {
        switch self {
        case .auto:
            nil
        case .mlx:
            .mlx
        case .gguf:
            .gguf
        }
    }
}

public enum ModelFormat: String, Codable, Hashable, Sendable {
    case mlx
    case gguf
    case unknown
}

public enum ModelArchitecture: String, Codable, Hashable, Sendable {
    case llama
    case qwen
    case gemma
    case mistral
    case phi
    case other
    case unknown
}

public enum ModelCheckVerdict: String, Codable, Hashable, Sendable {
    case supportedAndLikelyFits = "supported_and_likely_fits"
    case supportedButTight = "supported_but_tight"
    case supportedButContextLimited = "supported_but_context_limited"
    case supportedButMetadataIncomplete = "supported_but_metadata_incomplete"
    case unsupportedFormat = "unsupported_format"
    case unsupportedArchitecture = "unsupported_architecture"
    case insufficientMemory = "insufficient_memory"
    case unknown
}

public struct HostMachineProfile: Codable, Hashable, Sendable {
    public var machineModel: String?
    public var chipDescription: String?
    public var totalMemoryGB: Double?
    public var availableMemoryGB: Double?
    public var safeBudgetGB: Double?
    public var warnings: [String]

    public init(
        machineModel: String? = nil,
        chipDescription: String? = nil,
        totalMemoryGB: Double? = nil,
        availableMemoryGB: Double? = nil,
        safeBudgetGB: Double? = nil,
        warnings: [String] = []
    ) {
        self.machineModel = machineModel
        self.chipDescription = chipDescription
        self.totalMemoryGB = totalMemoryGB
        self.availableMemoryGB = availableMemoryGB
        self.safeBudgetGB = safeBudgetGB
        self.warnings = warnings
    }
}

public struct ModelMetadata: Codable, Hashable, Sendable {
    public var sourceIdentifier: String
    public var displayName: String
    public var backend: BackendKind?
    public var format: ModelFormat
    public var architecture: ModelArchitecture
    public var parameterCountB: Double?
    public var quantization: String?
    public var availableVariants: [String]
    public var selectedVariant: String?
    public var effectiveBits: Double?
    public var estimatedWeightsGB: Double?
    public var ggufFileCount: Int
    public var selectedGGUFFile: String?
    public var isSplitGGUF: Bool
    public var isMultimodal: Bool?
    public var isAdapter: Bool
    public var baseModelID: String?
    public var notes: [String]
    public var warnings: [String]

    public init(
        sourceIdentifier: String,
        displayName: String,
        backend: BackendKind? = nil,
        format: ModelFormat = .unknown,
        architecture: ModelArchitecture = .unknown,
        parameterCountB: Double? = nil,
        quantization: String? = nil,
        availableVariants: [String] = [],
        selectedVariant: String? = nil,
        effectiveBits: Double? = nil,
        estimatedWeightsGB: Double? = nil,
        ggufFileCount: Int = 0,
        selectedGGUFFile: String? = nil,
        isSplitGGUF: Bool = false,
        isMultimodal: Bool? = nil,
        isAdapter: Bool = false,
        baseModelID: String? = nil,
        notes: [String] = [],
        warnings: [String] = []
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.displayName = displayName
        self.backend = backend
        self.format = format
        self.architecture = architecture
        self.parameterCountB = parameterCountB
        self.quantization = quantization
        self.availableVariants = availableVariants
        self.selectedVariant = selectedVariant
        self.effectiveBits = effectiveBits
        self.estimatedWeightsGB = estimatedWeightsGB
        self.ggufFileCount = ggufFileCount
        self.selectedGGUFFile = selectedGGUFFile
        self.isSplitGGUF = isSplitGGUF
        self.isMultimodal = isMultimodal
        self.isAdapter = isAdapter
        self.baseModelID = baseModelID
        self.notes = notes
        self.warnings = warnings
    }
}

public struct ModelCheckResult: Codable, Hashable, Sendable {
    public var model: String
    public var backend: BackendKind?
    public var backendLabel: String
    public var format: ModelFormat
    public var architecture: ModelArchitecture
    public var parameterCountB: Double?
    public var quantization: String?
    public var selectedVariant: String?
    public var availableVariants: [String]
    public var effectiveBits: Double?
    public var contextTokens: Int
    public var estimatedWeightsGB: Double?
    public var estimatedRuntimeGB: Double?
    public var safeLocalBudgetGB: Double?
    public var verdict: ModelCheckVerdict
    public var confidence: Double?
    public var notes: [String]
    public var warnings: [String]
    public var host: HostMachineProfile
    public var metadata: ModelMetadata

    public init(
        model: String,
        backend: BackendKind?,
        backendLabel: String,
        format: ModelFormat,
        architecture: ModelArchitecture,
        parameterCountB: Double?,
        quantization: String?,
        selectedVariant: String?,
        availableVariants: [String],
        effectiveBits: Double?,
        contextTokens: Int,
        estimatedWeightsGB: Double?,
        estimatedRuntimeGB: Double?,
        safeLocalBudgetGB: Double?,
        verdict: ModelCheckVerdict,
        confidence: Double?,
        notes: [String],
        warnings: [String],
        host: HostMachineProfile,
        metadata: ModelMetadata
    ) {
        self.model = model
        self.backend = backend
        self.backendLabel = backendLabel
        self.format = format
        self.architecture = architecture
        self.parameterCountB = parameterCountB
        self.quantization = quantization
        self.selectedVariant = selectedVariant
        self.availableVariants = availableVariants
        self.effectiveBits = effectiveBits
        self.contextTokens = contextTokens
        self.estimatedWeightsGB = estimatedWeightsGB
        self.estimatedRuntimeGB = estimatedRuntimeGB
        self.safeLocalBudgetGB = safeLocalBudgetGB
        self.verdict = verdict
        self.confidence = confidence
        self.notes = notes
        self.warnings = warnings
        self.host = host
        self.metadata = metadata
    }
}
