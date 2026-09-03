import Foundation

// esh 2.1 UCMR, Stage 0 — the CapabilityProvider abstraction. A provider is dispatched on CAPABILITY
// (not model format) and produces a typed CapabilityEvent stream. This generalizes BackendRuntime and
// is intended to subsume the speech special-cases over time (superseding a standalone SpeechBackend
// seam). See docs/UCMR_ARCHITECTURE.md §4.

/// The execution substrate a provider runs on. Distinct from `BackendKind` (which is a model *format*):
/// a provider may be a Core ML / Apple-Vision path or a Python-bridge path, not just an LLM format.
public enum RuntimeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case mlx
    case gguf
    case apple            // Apple FoundationModels
    case appleVision      // Apple Vision framework (OCR etc.)
    case python           // MLX/other via the Python bridge
    case coreml
    case native           // pure-Swift (e.g. JSON-IR → SVG renderer)
}

public struct ResourceRequirements: Codable, Hashable, Sendable {
    public var estimatedMemoryGB: Double?
    public var estimatedDiskGB: Double?
    public var requiresNetworkForInstall: Bool
    public init(estimatedMemoryGB: Double? = nil, estimatedDiskGB: Double? = nil, requiresNetworkForInstall: Bool = false) {
        self.estimatedMemoryGB = estimatedMemoryGB
        self.estimatedDiskGB = estimatedDiskGB
        self.requiresNetworkForInstall = requiresNetworkForInstall
    }
    public static let none = ResourceRequirements()
}

/// Declarative metadata a provider advertises to the registry, scheduler and Model Fit.
public struct CapabilityProviderDescriptor: Codable, Hashable, Sendable {
    public var id: String
    public var capabilities: [CapabilityID]
    public var acceptedInputs: [ModelModality]
    public var producedOutputs: [ModelModality]
    public var backend: RuntimeKind
    public var modelFamily: String?
    public var streaming: Bool
    public var structuredOutput: Bool
    /// The least privilege this provider needs to run (media-only providers stay at artifact-only).
    public var requiredPrivilege: PrivilegeLevel
    /// The preview mode this provider's output supports, if any.
    public var previewMode: PreviewDescriptor.Mode

    public init(id: String,
                capabilities: [CapabilityID],
                acceptedInputs: [ModelModality],
                producedOutputs: [ModelModality],
                backend: RuntimeKind,
                modelFamily: String? = nil,
                streaming: Bool = false,
                structuredOutput: Bool = false,
                requiredPrivilege: PrivilegeLevel = .artifactOnly,
                previewMode: PreviewDescriptor.Mode = .none) {
        self.id = id
        self.capabilities = capabilities
        self.acceptedInputs = acceptedInputs
        self.producedOutputs = producedOutputs
        self.backend = backend
        self.modelFamily = modelFamily
        self.streaming = streaming
        self.structuredOutput = structuredOutput
        self.requiredPrivilege = requiredPrivilege
        self.previewMode = previewMode
    }
}

/// The scheduler's resolved choice for a request, handed to the provider to execute.
public struct ResolvedExecutionRequest: Sendable {
    public var request: ExecutionRequest
    public var modelID: String?
    public var install: ModelInstall?
    public init(request: ExecutionRequest, modelID: String? = nil, install: ModelInstall? = nil) {
        self.request = request
        self.modelID = modelID
        self.install = install
    }
}

/// Ambient services a provider may use (artifact persistence, the warm pool, storage root).
public struct ExecutionContext: Sendable {
    public var root: PersistenceRoot
    public var artifactStore: ArtifactStore
    public var lifecycle: RuntimeLifecycleManager?
    public init(root: PersistenceRoot, artifactStore: ArtifactStore, lifecycle: RuntimeLifecycleManager? = nil) {
        self.root = root
        self.artifactStore = artifactStore
        self.lifecycle = lifecycle
    }
}

public protocol CapabilityProvider: Sendable {
    var descriptor: CapabilityProviderDescriptor { get }
    func execute(_ request: ResolvedExecutionRequest,
                 context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error>
    func unload() async
}

public extension CapabilityProvider {
    func unload() async {}
}

/// Maps a request input to a coarse modality for candidate filtering.
public extension CapabilityInput {
    var modality: ModelModality {
        switch payload {
        case .text: return .text
        case .structured: return .json
        case .embedding: return .embedding
        case .attachment(let a):
            switch a.kind {
            case .image: return .image
            case .audio: return .audio
            case .video: return .video
            case .document: return .text   // documents are consumed as text today; refine when doc-VLM lands
            case .other: return .text
            }
        }
    }
}

/// Resolves a capability request to compatible providers. Dispatched on capability × input/output
/// modalities — NOT model format. The existing format-keyed InferenceBackendRegistry becomes one
/// contributor (its LLM/text providers) rather than the whole story.
public struct CapabilityRegistry: Sendable {
    private var providers: [any CapabilityProvider]

    public init(providers: [any CapabilityProvider] = []) {
        self.providers = providers
    }

    public mutating func register(_ provider: any CapabilityProvider) {
        providers.append(provider)
    }

    public var all: [any CapabilityProvider] { providers }

    /// Candidate providers for a capability that accept the given input modalities and can produce the
    /// requested output modality. Empty means "no local provider can do this" (an honest failure).
    public func providers(for capability: CapabilityID,
                          inputs: [ModelModality],
                          output: ModelModality) -> [any CapabilityProvider] {
        providers.filter { p in
            let d = p.descriptor
            guard d.capabilities.contains(capability) else { return false }
            guard Set(inputs).isSubset(of: Set(d.acceptedInputs)) else { return false }
            guard d.producedOutputs.contains(output) else { return false }
            return true
        }
    }

    /// Convenience: candidates for a whole request.
    public func candidates(for request: ExecutionRequest) -> [any CapabilityProvider] {
        let inputMods = Array(Set(request.inputs.map { $0.modality }))
        return providers(for: request.capability, inputs: inputMods, output: request.output.modality)
    }
}
