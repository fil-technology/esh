import Foundation
import EshCore
import EshRuntime

// Native, in-process instruction/img2img image editing (`image.edit`) via MLX-Swift's StableDiffusion
// (SDXL-Turbo img2img by default). No Python — runs under the macOS App Sandbox with weights as data. The
// pixel-producing engine is injected (`ImageEditFn`) so the provider wiring (discovery/progress/artifact/
// cancellation/errors) is deterministically testable; the concrete MLX engine lives in EshImageEdit.swift.

/// Edit parameters resolved from the request options.
public struct EshImageEditParams: Sendable {
    /// How much the source image is transformed (0 = unchanged, 1 = full re-generation). img2img "strength".
    public var strength: Float
    public var steps: Int
    public var seed: UInt64?
    public var negativePrompt: String
    public var cfgWeight: Float?
    /// The source image is downscaled so its longest edge is at most this many pixels (bounds memory).
    public var maximumEdge: Int
    public init(strength: Float, steps: Int, seed: UInt64?, negativePrompt: String,
                cfgWeight: Float?, maximumEdge: Int) {
        self.strength = strength; self.steps = steps; self.seed = seed
        self.negativePrompt = negativePrompt; self.cfgWeight = cfgWeight; self.maximumEdge = maximumEdge
    }
}

/// Reuses `ImageGenChunk` (progress → final PNG) from the generate provider.
public typealias ImageEditFn = @Sendable (_ imagePath: String, _ prompt: String, _ params: EshImageEditParams)
    -> AsyncThrowingStream<ImageGenChunk, Error>

public final class MLXImageEditProvider: CapabilityProvider, CapabilityAvailabilityRefreshing, @unchecked Sendable {
    public let descriptor: CapabilityProviderDescriptor
    private let modelID: String
    private let edit: ImageEditFn
    private let supported: Bool
    private let readyProbe: (@Sendable () -> Bool)?
    private let stateBox: StateBox

    public init(modelID: String, supported: Bool, edit: @escaping ImageEditFn,
                readyProbe: (@Sendable () -> Bool)? = nil) {
        self.modelID = modelID
        self.supported = supported
        self.edit = edit
        self.readyProbe = readyProbe
        self.stateBox = StateBox(supported ? .requiresDownload(modelID: nil, bytes: nil) : .unsupportedOnPlatform)
        self.descriptor = CapabilityProviderDescriptor(
            id: "mlx-image-edit", capabilities: [.imageEdit],
            acceptedInputs: [.image, .text], producedOutputs: [.image],
            backend: .mlx, streaming: true, structuredOutput: false,
            requiredPrivilege: .artifactOnly, previewMode: .none)
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
        let inputs = request.request.inputs
        let prompt = inputs.compactMap { i -> String? in
            if case .text(let t) = i.payload { return t }; return nil
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let imagePath = Self.imageInputPath(inputs)
        let params = Self.params(from: request.request.options.values)
        let edit = self.edit
        let supported = self.supported
        let stateBox = self.stateBox
        let store = context.artifactStore
        let providerID = descriptor.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard supported else {
                    continuation.yield(.failed(message: "image editing is not supported on this platform")); continuation.finish(); return
                }
                guard let imagePath, !imagePath.isEmpty else {
                    continuation.yield(.failed(message: "image.edit requires an image input")); continuation.finish(); return
                }
                guard !prompt.isEmpty else {
                    continuation.yield(.failed(message: "image.edit requires a text instruction")); continuation.finish(); return
                }
                // Fail cleanly if the configured (external) assets volume is unavailable and the model is not
                // already loaded in-process — never silently fall back to the internal disk.
                if case .ready = stateBox.get() {} else if case .unavailable(let reason) = StorageService().availability(root: context.root) {
                    continuation.yield(.failed(message: "model storage is unavailable: \(reason)")); continuation.finish(); return
                }
                do {
                    continuation.yield(.status("loading image-edit model"))
                    var produced = false
                    for try await chunk in edit(imagePath, prompt, params) {
                        try Task.checkCancellation()
                        switch chunk {
                        case .progress(let p):
                            continuation.yield(.progress(p))
                        case .image(let png):
                            let artifact = Artifact(
                                kind: .image, mimeType: "image/png", files: [], entrypoint: "edited.png",
                                generatedBy: ArtifactProvenance(providerID: providerID, capability: .imageEdit))
                            let saved = try store.save(artifact, files: ["edited.png": png])
                            produced = true
                            stateBox.set(.ready)
                            continuation.yield(.artifactProduced(saved))
                        }
                    }
                    try Task.checkCancellation()
                    guard produced else {
                        continuation.yield(.failed(message: "image edit produced no image")); continuation.finish(); return
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

    /// The filesystem path of the first image input, resolving a `file://` URI (which may be percent-encoded).
    static func imageInputPath(_ inputs: [CapabilityInput]) -> String? {
        for i in inputs {
            if case .attachment(let a) = i.payload, a.kind == .image, let uri = a.uri {
                if uri.hasPrefix("file://"), let url = URL(string: uri), url.isFileURL { return url.path }
                return uri
            }
        }
        return nil
    }

    /// Resolve edit parameters from request options. Defaults suit SDXL-Turbo img2img (few steps, no CFG).
    static func params(from options: [String: JSONValue]) -> EshImageEditParams {
        func int(_ key: String) -> Int? {
            switch options[key] { case .int(let i): return i; case .double(let d): return Int(d); default: return nil }
        }
        func float(_ key: String) -> Float? {
            switch options[key] { case .int(let i): return Float(i); case .double(let d): return Float(d); default: return nil }
        }
        func string(_ key: String) -> String? { if case .string(let s)? = options[key] { return s }; return nil }
        let strength = float("strength").map { max(0.05, min(1.0, $0)) } ?? 0.7
        let steps = int("steps").map { max(1, min(100, $0)) } ?? 4      // SDXL-Turbo: few steps
        let seed = int("seed").map { UInt64(bitPattern: Int64($0)) }
        let maxEdge = int("maximumEdge").map { max(256, min(1536, ($0 / 8) * 8)) } ?? 768
        return EshImageEditParams(strength: strength, steps: steps, seed: seed,
                                  negativePrompt: string("negativePrompt") ?? "",
                                  cfgWeight: float("cfg"), maximumEdge: maxEdge)
    }

    final class StateBox: @unchecked Sendable {
        private let lock = NSLock(); private var value: CapabilityAvailability
        init(_ v: CapabilityAvailability) { value = v }
        func get() -> CapabilityAvailability { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: CapabilityAvailability) { lock.lock(); value = v; lock.unlock() }
    }
}
