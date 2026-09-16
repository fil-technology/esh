import Foundation
import EshCore
import EshRuntime

// Native, in-process image understanding (VLM) via MLX-Swift. `image.understand` runs a vision-language
// model (e.g. Qwen2-VL-2B-4bit) on an image + prompt entirely on device — no Python. The token-producing
// engine is injected (`VLMStreamFn`) so the provider's wiring (discovery/streaming/cancellation/errors) is
// deterministically testable; the concrete MLX-backed engine (model load + reuse) lives in EshVision.swift.

public typealias VLMStreamFn = @Sendable (_ imagePath: String, _ prompt: String) -> AsyncThrowingStream<String, Error>

public final class MLXVisionUnderstandProvider: CapabilityProvider, CapabilityAvailabilityRefreshing, @unchecked Sendable {
    public let descriptor: CapabilityProviderDescriptor
    private let modelID: String
    private let stream: VLMStreamFn
    private let supported: Bool
    private let readyProbe: (@Sendable () -> Bool)?
    private let stateBox: StateBox

    public init(modelID: String, supported: Bool, stream: @escaping VLMStreamFn, readyProbe: (@Sendable () -> Bool)? = nil) {
        self.modelID = modelID
        self.supported = supported
        self.stream = stream
        self.readyProbe = readyProbe
        self.stateBox = StateBox(supported ? .requiresDownload(modelID: nil, bytes: nil) : .unsupportedOnPlatform)
        self.descriptor = CapabilityProviderDescriptor(
            id: "mlx-vision-understand", capabilities: [.imageUnderstand],
            acceptedInputs: [.text, .image], producedOutputs: [.text],
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
        let prompt = request.request.inputs.compactMap { i -> String? in
            if case .text(let t) = i.payload { return t }; return nil
        }.joined(separator: " ")
        let attachment = request.request.inputs.compactMap { i -> EshAttachment? in
            if case .attachment(let a) = i.payload, a.kind == .image { return a }; return nil
        }.first
        let stream = self.stream
        let supported = self.supported
        let stateBox = self.stateBox
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard supported else {
                    continuation.yield(.failed(message: "image understanding is not supported on this platform")); continuation.finish(); return
                }
                // If the model isn't already loaded in this process, it must be read from (or downloaded to)
                // the configured assets volume — fail cleanly if that external volume is unavailable, rather
                // than silently writing to the internal disk. In-process reuse (state already .ready) skips this.
                if case .ready = stateBox.get() {} else if case .unavailable(let reason) = StorageService().availability(root: context.root) {
                    continuation.yield(.failed(message: "model storage is unavailable: \(reason)")); continuation.finish(); return
                }
                guard let imagePath = Self.imagePath(from: attachment) else {
                    continuation.yield(.failed(message: "image.understand requires an image attachment (uri or base64)")); continuation.finish(); return
                }
                let effectivePrompt = prompt.isEmpty ? "Describe this image." : prompt
                do {
                    continuation.yield(.status("loading vision model"))
                    var produced = false
                    for try await token in stream(imagePath, effectivePrompt) {
                        try Task.checkCancellation()
                        if !produced { produced = true; stateBox.set(.ready) }
                        continuation.yield(.textDelta(token))
                    }
                    try Task.checkCancellation()
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

    static func imagePath(from attachment: EshAttachment?) -> String? {
        guard let attachment else { return nil }
        if let uri = attachment.uri, !uri.isEmpty {
            if let url = URL(string: uri), url.isFileURL { return url.path }
            return uri
        }
        if let b64 = attachment.base64, let data = Data(base64Encoded: b64) {
            let ext = (attachment.mimeType?.contains("png") == true) ? "png" : "jpg"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            do { try data.write(to: url); return url.path } catch { return nil }
        }
        return nil
    }

    final class StateBox: @unchecked Sendable {
        private let lock = NSLock(); private var value: CapabilityAvailability
        init(_ v: CapabilityAvailability) { value = v }
        func get() -> CapabilityAvailability { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: CapabilityAvailability) { lock.lock(); value = v; lock.unlock() }
    }
}
