import Foundation
import EshCore
import EshRuntime
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Native, in-process, content-preserving INSTRUCT image editing (`image.edit`) via the standalone
// mlx-swift-image-edit package (InstructPix2Pix / SD1.5 on MLX). No Python — runs under the macOS App
// Sandbox with weights as data. This is the TRUE instruct edit that preserves subject/scene, distinct from
// `image.restyle` (SDXL-Turbo img2img, which regenerates from the prompt). The pixel-producing engine is
// injected (`InstructImageEditFn`) so the provider wiring (discovery/progress/artifact/cancellation/errors)
// is deterministically testable; the concrete MLX engine lives in EshImageEdit.swift.

/// Instruct-edit parameters resolved from the request options.
public struct EshImageEditParams: Sendable {
    public var steps: Int
    /// Text (instruction) guidance — how strongly to follow the edit instruction. diffusers "guidance_scale".
    public var textGuidance: Float
    /// Image guidance — how strongly to preserve the source. diffusers "image_guidance_scale".
    public var imageGuidance: Float
    public var seed: UInt64?
    public var negativePrompt: String
    /// The source image is downscaled so its longest edge is at most this many pixels (bounds memory);
    /// both dimensions are rounded to a multiple of 8 (the VAE stride).
    public var maximumEdge: Int
    public init(steps: Int, textGuidance: Float, imageGuidance: Float, seed: UInt64?,
                negativePrompt: String, maximumEdge: Int) {
        self.steps = steps; self.textGuidance = textGuidance; self.imageGuidance = imageGuidance
        self.seed = seed; self.negativePrompt = negativePrompt; self.maximumEdge = maximumEdge
    }
}

/// Reuses `ImageGenChunk` (progress → final PNG) from the generate provider.
public typealias InstructImageEditFn = @Sendable (_ imagePath: String, _ prompt: String, _ params: EshImageEditParams)
    -> AsyncThrowingStream<ImageGenChunk, Error>

public final class MLXInstructImageEditProvider: CapabilityProvider, CapabilityAvailabilityRefreshing, @unchecked Sendable {
    public let descriptor: CapabilityProviderDescriptor
    private let modelID: String
    private let edit: InstructImageEditFn
    private let supported: Bool
    private let readyProbe: (@Sendable () -> Bool)?
    private let stateBox: StateBox

    /// - Parameters:
    ///   - providerID: descriptor id used for provider/model selection (the app pins it via `request.model`).
    ///     Defaults to the InstructPix2Pix tier; the PhotoMaker identity tier passes its own id here.
    ///   - modelFamily: optional family alias also matchable by `request.model`.
    public init(modelID: String, supported: Bool, edit: @escaping InstructImageEditFn,
                readyProbe: (@Sendable () -> Bool)? = nil,
                providerID: String = "mlx-instruct-image-edit", modelFamily: String? = "instruct-pix2pix") {
        self.modelID = modelID
        self.supported = supported
        self.edit = edit
        self.readyProbe = readyProbe
        self.stateBox = StateBox(supported ? .requiresDownload(modelID: nil, bytes: nil) : .unsupportedOnPlatform)
        self.descriptor = CapabilityProviderDescriptor(
            id: providerID, capabilities: [.imageEdit],
            acceptedInputs: [.image, .text], producedOutputs: [.image],
            backend: .mlx, modelFamily: modelFamily, streaming: true, structuredOutput: false,
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
        let resolvedImage = Self.resolveImageInput(inputs)
        let params = Self.params(from: request.request.options.values)
        let edit = self.edit
        let supported = self.supported
        let stateBox = self.stateBox
        let store = context.artifactStore
        let providerID = descriptor.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { resolvedImage?.cleanup?() }
                guard supported else {
                    continuation.yield(.failed(message: "instruct image edit is not supported on this platform")); continuation.finish(); return
                }
                guard let imagePath = resolvedImage?.path, !imagePath.isEmpty else {
                    continuation.yield(.failed(message: "image.edit requires an image input")); continuation.finish(); return
                }
                guard !prompt.isEmpty else {
                    continuation.yield(.failed(message: "image.edit requires an edit instruction (prompt)")); continuation.finish(); return
                }
                // Fail cleanly if the configured (external) assets volume is unavailable and the model is not
                // already loaded in-process — never silently fall back to the internal disk.
                if case .ready = stateBox.get() {} else if case .unavailable(let reason) = StorageService().availability(root: context.root) {
                    continuation.yield(.failed(message: "model storage is unavailable: \(reason)")); continuation.finish(); return
                }
                do {
                    continuation.yield(.status("loading instruct image-edit model"))
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
                        continuation.yield(.failed(message: "instruct image edit produced no image")); continuation.finish(); return
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

    /// A resolved source image: a filesystem path, plus an optional cleanup for a temp file we materialized
    /// from inline base64.
    struct ResolvedImage { let path: String; let cleanup: (@Sendable () -> Void)? }

    /// Resolve the first image input to a filesystem path. Accepts a `file://` URI (percent-encoded) or a
    /// plain path; if the attachment carries inline base64 instead, it is decoded to a temp PNG.
    static func resolveImageInput(_ inputs: [CapabilityInput]) -> ResolvedImage? {
        for i in inputs {
            guard case .attachment(let a) = i.payload, a.kind == .image else { continue }
            if let uri = a.uri, !uri.isEmpty {
                if uri.hasPrefix("file://"), let url = URL(string: uri), url.isFileURL {
                    return ResolvedImage(path: url.path, cleanup: nil)
                }
                return ResolvedImage(path: uri, cleanup: nil)
            }
            if let b64 = a.base64, let data = Data(base64Encoded: b64) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
                if (try? data.write(to: tmp)) != nil {
                    let path = tmp.path
                    return ResolvedImage(path: path, cleanup: { try? FileManager.default.removeItem(atPath: path) })
                }
            }
        }
        return nil
    }

    /// Resolve edit parameters from request options. Defaults are the validated InstructPix2Pix settings
    /// (20 steps, textGuidance 7.0, imageGuidance 1.5).
    static func params(from options: [String: JSONValue]) -> EshImageEditParams {
        func int(_ key: String) -> Int? {
            switch options[key] { case .int(let i): return i; case .double(let d): return Int(d); default: return nil }
        }
        func float(_ keys: [String]) -> Float? {
            for key in keys {
                switch options[key] { case .int(let i): return Float(i); case .double(let d): return Float(d); default: continue }
            }
            return nil
        }
        func string(_ key: String) -> String? { if case .string(let s)? = options[key] { return s }; return nil }
        let steps = int("steps").map { max(1, min(100, $0)) } ?? 20
        // Accept both esh-generic ("textGuidance"/"imageGuidance") and diffusers-style option names.
        let textG = float(["textGuidance", "guidanceScale", "cfg"]).map { max(1.0, min(20.0, $0)) } ?? 7.0
        let imageG = float(["imageGuidance", "imageGuidanceScale"]).map { max(0.0, min(5.0, $0)) } ?? 1.5
        let seed = int("seed").map { UInt64(bitPattern: Int64($0)) }
        let maxEdge = int("maximumEdge").map { max(256, min(1024, ($0 / 8) * 8)) } ?? 512
        return EshImageEditParams(steps: steps, textGuidance: textG, imageGuidance: imageG, seed: seed,
                                  negativePrompt: string("negativePrompt") ?? "", maximumEdge: maxEdge)
    }

    final class StateBox: @unchecked Sendable {
        private let lock = NSLock(); private var value: CapabilityAvailability
        init(_ v: CapabilityAvailability) { value = v }
        func get() -> CapabilityAvailability { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: CapabilityAvailability) { lock.lock(); value = v; lock.unlock() }
    }
}
