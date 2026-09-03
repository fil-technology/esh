import Foundation

// esh 2.1 UCMR, Stage 2 — vision understanding (image + text → text) via mlx-vlm. This is the first real
// non-text INPUT modality: images now actually reach the model (the bridge gained an mlx-vlm image path;
// previously mlx_vlm was imported only for KV-cache and images were dropped). Text output, so the result
// flows through the same text channel as language.generate.

/// Thin wrapper over the `mlx-vlm-generate` bridge op (mirrors SpeechToTextService).
public struct VisionUnderstandingService: Sendable {
    private let bridge: MLXBridge
    public init(bridge: MLXBridge = .init()) { self.bridge = bridge }

    public func understand(imagePaths: [String], prompt: String, model: String,
                           maxTokens: Int = 512, temperature: Double = 0.0) throws -> String {
        let response: Response = try bridge.run(
            command: "mlx-vlm-generate",
            request: Request(modelPath: model, prompt: prompt, images: imagePaths,
                             config: Config(maxTokens: maxTokens, temperature: temperature)),
            as: Response.self)
        return response.text
    }

    private struct Config: Codable, Sendable { let maxTokens: Int; let temperature: Double }
    private struct Request: Codable, Sendable {
        let modelPath: String; let prompt: String; let images: [String]; let config: Config
    }
    private struct Response: Codable, Sendable { let text: String }
}

public struct VisionUnderstandProvider: CapabilityProvider {
    public typealias UnderstandFn = @Sendable (_ imagePaths: [String], _ prompt: String, _ model: String, _ maxTokens: Int) throws -> String

    public let descriptor: CapabilityProviderDescriptor
    private let understand: UnderstandFn

    public init(id: String = "vision-understand", understand: @escaping UnderstandFn) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.imageUnderstand],   // OCR is served by the zero-dep Apple Vision provider
            acceptedInputs: [.text, .image],
            producedOutputs: [.text],
            backend: .python,
            streaming: false,
            structuredOutput: false,
            requiredPrivilege: .artifactOnly,
            previewMode: .none)
        self.understand = understand
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let understand = self.understand
        return AsyncThrowingStream { cont in
            let task = Task {
                var tempPaths: [String] = []
                defer { for p in tempPaths { try? FileManager.default.removeItem(atPath: p) } }
                do {
                    guard let model = req.model, !model.isEmpty else {
                        throw CapabilityError.failed("vision understanding requires an explicit vision model")
                    }
                    let prompt = req.inputs.compactMap { if case .text(let t) = $0.payload { return t } else { return nil } }
                        .joined(separator: "\n")
                    var imagePaths: [String] = []
                    for input in req.inputs {
                        if case .attachment(let a) = input.payload, a.kind == .image {
                            let (path, isTemp) = try Self.materialize(a, root: context.root)
                            imagePaths.append(path)
                            if isTemp { tempPaths.append(path) }
                        }
                    }
                    guard !imagePaths.isEmpty else { throw CapabilityError.failed("vision understanding requires at least one image input") }

                    cont.yield(.status("understanding \(imagePaths.count) image(s)"))
                    let maxTokens = VisionUnderstandProvider.intOption(req, "maxTokens") ?? 512
                    let text = try understand(imagePaths, prompt.isEmpty ? "Describe this image." : prompt, model, maxTokens)
                    if !text.isEmpty { cont.yield(.textDelta(text)) }
                    cont.yield(.done(finishReason: "stop"))
                    cont.finish()
                } catch {
                    cont.yield(.failed(message: error.localizedDescription))
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Resolve an image attachment to a local file path. `uri` file paths are used as-is; inline base64
    /// is written to a temp file (caller deletes temps). Returns (path, isTemporary).
    static func materialize(_ attachment: EshAttachment, root: PersistenceRoot) throws -> (String, Bool) {
        if let uri = attachment.uri, !uri.isEmpty {
            let path = uri.hasPrefix("file://") ? URL(string: uri)?.path ?? uri : uri
            guard FileManager.default.fileExists(atPath: path) else {
                throw CapabilityError.failed("image not found at \(path)")
            }
            return (path, false)
        }
        guard let b64 = attachment.base64, let data = Data(base64Encoded: Self.stripDataURLPrefix(b64)) else {
            throw CapabilityError.failed("image attachment has no readable content")
        }
        let ext = Self.ext(for: attachment.mimeType)
        try FileManager.default.createDirectory(at: root.tempURL, withIntermediateDirectories: true)
        let url = root.tempURL.appendingPathComponent("vlm-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return (url.path, true)
    }

    static func stripDataURLPrefix(_ s: String) -> String {
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") { return String(s[s.index(after: comma)...]) }
        return s
    }

    static func ext(for mime: String?) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        // Audio (diarization/STT materialize through here too): a correct extension matters — soundfile/
        // librosa infer the container from it, so a WAV named ".png" fails to decode.
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/flac": return "flac"
        case "audio/ogg": return "ogg"
        default:
            if let mime, mime.hasPrefix("audio/") { return "wav" }
            return "png"
        }
    }

    static func intOption(_ req: ExecutionRequest, _ key: String) -> Int? {
        switch req.options.values[key] {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
}
