import Foundation
import EshCore
import EshRuntime

// Native, in-process text->image generation (`image.generate`) via MLX-Swift's StableDiffusion (SD 2.1 base
// by default). No Python. The pixel-producing engine is injected (`ImageGenFn`) so the provider's wiring
// (discovery/progress/artifact/cancellation/errors) is deterministically testable; the concrete MLX-backed
// engine (model download + reuse + diffusion loop) lives in EshImageGen.swift.

/// A generation parameter set resolved from the request options.
public struct EshImageGenParams: Sendable {
    public var steps: Int
    public var seed: UInt64?
    public var width: Int
    public var height: Int
    public var negativePrompt: String
    public var cfgWeight: Float?
    public init(steps: Int, seed: UInt64?, width: Int, height: Int,
                negativePrompt: String, cfgWeight: Float?) {
        self.steps = steps; self.seed = seed; self.width = width; self.height = height
        self.negativePrompt = negativePrompt; self.cfgWeight = cfgWeight
    }
}

/// A chunk from the generation engine: incremental progress (0...1) then the final PNG bytes.
public enum ImageGenChunk: Sendable {
    case progress(Double)
    case image(Data)
}

public typealias ImageGenFn = @Sendable (_ prompt: String, _ params: EshImageGenParams)
    -> AsyncThrowingStream<ImageGenChunk, Error>

public final class MLXImageGenerateProvider: CapabilityProvider, CapabilityAvailabilityRefreshing, @unchecked Sendable {
    public let descriptor: CapabilityProviderDescriptor
    private let modelID: String
    private let generate: ImageGenFn
    private let supported: Bool
    private let readyProbe: (@Sendable () -> Bool)?
    private let stateBox: StateBox

    public init(modelID: String, supported: Bool, generate: @escaping ImageGenFn,
                readyProbe: (@Sendable () -> Bool)? = nil) {
        self.modelID = modelID
        self.supported = supported
        self.generate = generate
        self.readyProbe = readyProbe
        self.stateBox = StateBox(supported ? .requiresDownload(modelID: nil, bytes: nil) : .unsupportedOnPlatform)
        self.descriptor = CapabilityProviderDescriptor(
            id: "mlx-image-generate", capabilities: [.imageGenerate],
            acceptedInputs: [.text], producedOutputs: [.image],
            backend: .mlx, streaming: true, structuredOutput: false,
            requiredPrivilege: .artifactOnly, previewMode: .none,
            supportsMultipleOutputs: true, maximumOutputCount: 4)
    }

    public func refreshAvailability() async {
        guard supported else { return }
        if let readyProbe { stateBox.set(readyProbe() ? .ready : .requiresDownload(modelID: nil, bytes: nil)) }
    }
    public func reportedAvailability(for capability: CapabilityID) -> CapabilityAvailability? {
        guard descriptor.capabilities.contains(capability) else { return nil }
        return stateBox.get()
    }

    public func execute(_ request: ResolvedExecutionRequest,
                        context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let prompt = request.request.inputs.compactMap { i -> String? in
            if case .text(let t) = i.payload { return t }; return nil
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let params = Self.params(from: request.request.options.values)
        // rc.22 multi-output: N variants from ONE execution, each a real generation with a deterministic
        // per-variant seed (index 0 == the requested/base seed, so single-output is byte-identical to before).
        // Native SD batch shares one seed across N draws and can't record a per-variant seed, so per-seed
        // generation is used — each artifact honestly records the seed that produced it. All share one batchID.
        let variantCount = max(1, request.request.outputCount ?? 1)
        let baseSeed = params.seed ?? UInt64.random(in: 0 ... UInt64.max)
        let batchID = UUID()
        let generate = self.generate
        let supported = self.supported
        let stateBox = self.stateBox
        let store = context.artifactStore
        let providerID = descriptor.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard supported else {
                    continuation.yield(.failed(message: "image generation is not supported on this platform")); continuation.finish(); return
                }
                guard !prompt.isEmpty else {
                    continuation.yield(.failed(message: "image.generate requires a text prompt")); continuation.finish(); return
                }
                // Fail cleanly if the configured (external) assets volume is unavailable and the model is not
                // already loaded in-process — never silently fall back to the internal disk.
                if case .ready = stateBox.get() {} else if case .unavailable(let reason) = StorageService().availability(root: context.root) {
                    continuation.yield(.failed(message: "model storage is unavailable: \(reason)")); continuation.finish(); return
                }
                do {
                    continuation.yield(.status("loading image model"))
                    var produced = false
                    for index in 0 ..< variantCount {
                        try Task.checkCancellation()
                        let seed = VariantSeed.derive(base: baseSeed, index: index)
                        var variantParams = params
                        variantParams.seed = seed
                        for try await chunk in generate(prompt, variantParams) {
                            try Task.checkCancellation()
                            switch chunk {
                            case .progress(let p):
                                // Monotonic across variants.
                                continuation.yield(.progress((Double(index) + p) / Double(variantCount)))
                            case .image(let png):
                                let artifact = Artifact(
                                    kind: .image, mimeType: "image/png", files: [], entrypoint: "generated.png",
                                    generatedBy: ArtifactProvenance(providerID: providerID, capability: .imageGenerate,
                                                                    batchID: batchID, variantIndex: index, seed: seed))
                                let saved = try store.save(artifact, files: ["generated.png": png])
                                produced = true
                                stateBox.set(.ready)
                                continuation.yield(.artifactProduced(saved))   // streamed as each variant completes
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard produced else {
                        continuation.yield(.failed(message: "image generation produced no image")); continuation.finish(); return
                    }
                    continuation.yield(.done(finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.yield(.failed(message: error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload() async {}

    /// Resolve generation parameters from request options; dimensions are snapped to multiples of 8 (the
    /// diffusion latent factor) and clamped to a sane range.
    static func params(from options: [String: JSONValue]) -> EshImageGenParams {
        func int(_ key: String) -> Int? {
            switch options[key] { case .int(let i): return i; case .double(let d): return Int(d); default: return nil }
        }
        func float(_ key: String) -> Float? {
            switch options[key] { case .int(let i): return Float(i); case .double(let d): return Float(d); default: return nil }
        }
        func string(_ key: String) -> String? {
            if case .string(let s)? = options[key] { return s }; return nil
        }
        func snap(_ v: Int) -> Int { max(256, min(1024, (v / 8) * 8)) }
        let w = int("width").map(snap) ?? 512
        let h = int("height").map(snap) ?? 512
        let steps = int("steps").map { max(1, min(100, $0)) } ?? 20
        let seed = int("seed").map { UInt64(bitPattern: Int64($0)) }
        return EshImageGenParams(steps: steps, seed: seed, width: w, height: h,
                                 negativePrompt: string("negativePrompt") ?? "", cfgWeight: float("cfg"))
    }

    final class StateBox: @unchecked Sendable {
        private let lock = NSLock(); private var value: CapabilityAvailability
        init(_ v: CapabilityAvailability) { value = v }
        func get() -> CapabilityAvailability { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: CapabilityAvailability) { lock.lock(); value = v; lock.unlock() }
    }
}
