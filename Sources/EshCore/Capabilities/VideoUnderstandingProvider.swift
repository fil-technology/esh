import Foundation

// esh 2.1 UCMR, Stage 3 — video.understand: a MULTI-PROVIDER pipeline, not a single model. It composes
// native metadata + adaptive keyframe extraction → VLM per frame, native audio extraction → STT, then a
// reasoning LLM fuses the timestamped visual captions + transcript to answer a question. The composed
// pipeline is exposed as a canonical ExecutionPlan (§9). Honest scope: this is SAMPLED-FRAME + AUDIO
// FUSION, not deep temporal modeling — the result and rationale say so.

public struct VideoMetadata: Sendable, Equatable {
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    public var nominalFrameRate: Double
    public var codec: String?
    public var hasAudio: Bool
    public init(durationSeconds: Double, width: Int, height: Int, nominalFrameRate: Double, codec: String?, hasAudio: Bool) {
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.codec = codec
        self.hasAudio = hasAudio
    }
}

/// Media operations behind a protocol so the pipeline is testable without real decode, and so the codec
/// backend (AVFoundation) can be swapped without touching the pipeline. Implementations must throw a
/// CapabilityError for corrupt/unsupported inputs.
public protocol VideoMediaExtractor: Sendable {
    func metadata(path: String) async throws -> VideoMetadata
    /// Extract one frame per timestamp (seconds); returns the written PNG file paths (temp; caller deletes).
    func extractKeyframes(path: String, timestampsSeconds: [Double], into dir: URL) async throws -> [String]
    /// Extract the audio track to a WAV file; returns its path, or nil when there is no audio track.
    func extractAudio(path: String, into dir: URL) async throws -> String?
}

/// Duration-aware adaptive frame sampling: more frames for longer clips up to a cap, evenly spread and
/// centered in their segment. Pure + deterministic → unit-testable. (Scene-change detection can refine
/// this later; today it is honest uniform sampling.)
public enum VideoFrameSampler {
    public static func sampleTimestamps(durationSeconds: Double, maxFrames: Int = 8, minSecondsPerFrame: Double = 2.0) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [0] }
        let byDuration = Int((durationSeconds / max(0.5, minSecondsPerFrame)).rounded(.up))
        let count = max(1, min(maxFrames, byDuration))
        let segment = durationSeconds / Double(count)
        return (0..<count).map { (Double($0) + 0.5) * segment }
    }
}

public struct VideoUnderstandingProvider: CapabilityProvider {
    public typealias DescribeFrameFn = @Sendable (_ imagePath: String, _ prompt: String, _ visionModel: String?) async throws -> String
    public typealias TranscribeFn = @Sendable (_ audioPath: String) async throws -> String
    public typealias FuseFn = @Sendable (_ request: ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    /// A more reliable fusion backend (Apple Intelligence on-device): (system, user, maxTokens) → (text, model).
    /// nil when unavailable. Preferred for the fusion step because small resident models leak control tokens.
    public typealias StrongFuseFn = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> (text: String, model: String)

    public let descriptor: CapabilityProviderDescriptor
    private let extractor: VideoMediaExtractor
    private let describeFrame: DescribeFrameFn
    private let transcribe: TranscribeFn
    private let fuse: FuseFn
    private let strongFuse: StrongFuseFn?

    public init(id: String = "video-understanding",
                extractor: VideoMediaExtractor,
                describeFrame: @escaping DescribeFrameFn,
                transcribe: @escaping TranscribeFn,
                fuse: @escaping FuseFn,
                strongFuse: StrongFuseFn? = nil) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.videoUnderstand],
            acceptedInputs: [.video, .text],
            producedOutputs: [.text, .json],
            backend: .native,          // the orchestrator is native; sub-steps run on python/mlx
            streaming: false,
            structuredOutput: false,
            requiredPrivilege: .artifactOnly,
            previewMode: .none)
        self.extractor = extractor
        self.describeFrame = describeFrame
        self.transcribe = transcribe
        self.fuse = fuse
        self.strongFuse = strongFuse
    }

    static let framePrompt = "Describe what is visible in this video frame in one concise sentence."

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let extractor = self.extractor
        let describeFrame = self.describeFrame
        let transcribe = self.transcribe
        let fuse = self.fuse
        let strongFuse = self.strongFuse
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                let work = context.root.tempURL.appendingPathComponent("video-\(UUID().uuidString)", isDirectory: true)
                var tempPaths: [String] = []
                defer {
                    for p in tempPaths { try? FileManager.default.removeItem(atPath: p) }
                    try? FileManager.default.removeItem(at: work)
                }
                do {
                    // Inputs: a video attachment + an optional text question.
                    guard let video = req.inputs.compactMap({ input -> EshAttachment? in
                        if case .attachment(let a) = input.payload, a.kind == .video { return a }
                        return nil
                    }).first else {
                        throw CapabilityError.failed("video understanding requires a video input")
                    }
                    let question = req.inputs.compactMap { input -> String? in
                        if case .text(let t) = input.payload { return t }
                        return nil
                    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    let videoPath = try Self.materializeVideo(video, into: work)
                    if videoPath.hasPrefix(work.path) { tempPaths.append(videoPath) }

                    // Step 1: metadata.
                    cont.yield(.status("reading video metadata"))
                    let meta = try await extractor.metadata(path: videoPath)
                    try Task.checkCancellation()

                    // Step 2: adaptive keyframe extraction.
                    let visionModel = Self.stringOption(req, "visionModel")
                    let maxFrames = TextToSVGProvider.intOption(req, "maxFrames") ?? 8
                    let timestamps = VideoFrameSampler.sampleTimestamps(durationSeconds: meta.durationSeconds, maxFrames: maxFrames)
                    cont.yield(.status("extracting \(timestamps.count) keyframes"))
                    let frames = try await extractor.extractKeyframes(path: videoPath, timestampsSeconds: timestamps, into: work)
                    tempPaths.append(contentsOf: frames)
                    guard !frames.isEmpty else { throw CapabilityError.failed("no frames could be extracted from the video") }

                    // Step 3: VLM per frame (with timestamp association).
                    var captions: [(t: Double, text: String)] = []
                    for (i, frame) in frames.enumerated() {
                        try Task.checkCancellation()
                        cont.yield(.progress(Double(i) / Double(frames.count)))
                        let t = i < timestamps.count ? timestamps[i] : 0
                        let caption = (try? await describeFrame(frame, Self.framePrompt, visionModel)) ?? ""
                        if !caption.isEmpty { captions.append((t, caption)) }
                    }

                    // Step 4/5: audio extraction + STT (only when there is an audio track).
                    var transcript = ""
                    if meta.hasAudio, let audioPath = try? await extractor.extractAudio(path: videoPath, into: work) {
                        tempPaths.append(audioPath)
                        try Task.checkCancellation()
                        cont.yield(.status("transcribing audio"))
                        transcript = (try? await transcribe(audioPath)) ?? ""
                    }

                    // Step 6: reasoning/fusion. Prefer the reliable backend (Apple Intelligence) when present —
                    // small resident models leak control tokens / produce degenerate summaries — and sanitize +
                    // validate the result, falling back to the other backend on a degenerate answer.
                    try Task.checkCancellation()
                    cont.yield(.status("reasoning over frames + audio"))
                    let maxTokens = TextToSVGProvider.intOption(req, "maxTokens") ?? 600
                    let system = Self.fusionSystem
                    let userPrompt = Self.fusionPrompt(question: question, meta: meta, captions: captions, transcript: transcript)
                    let residentAttempt: @Sendable () async throws -> (String, String?) = {
                        let resp = try await fuse(ExternalInferenceRequest(
                            model: req.model,
                            messages: [ExternalInferenceMessage(role: .system, text: system),
                                       ExternalInferenceMessage(role: .user, text: userPrompt)],
                            generation: GenerationConfig(maxTokens: maxTokens, temperature: 0.3)))
                        return (resp.outputText, resp.modelID)
                    }
                    var order: [@Sendable () async throws -> (String, String?)] = []
                    if let strongFuse {
                        order.append({ let r = try await strongFuse(system, userPrompt, maxTokens); return (r.text, r.model) })
                        order.append(residentAttempt)
                    } else {
                        order.append(residentAttempt)
                    }
                    var answer = ""
                    var fusionModel: String? = req.model
                    for attempt in order {
                        if Task.isCancelled { throw CancellationError() }
                        guard let (raw, model) = try? await attempt() else { continue }
                        let cleaned = Self.sanitizeFusion(raw)
                        if !Self.isDegenerate(cleaned) { answer = cleaned; fusionModel = model ?? req.model; break }
                        if answer.isEmpty { answer = cleaned; fusionModel = model ?? req.model }   // keep best-so-far
                    }
                    if Self.isDegenerate(answer) {
                        // No backend produced a usable summary — fail honestly rather than emit garbage.
                        throw CapabilityError.failed("the fusion model did not produce a usable summary of this video")
                    }

                    // Canonical composed pipeline.
                    let plan = Self.buildPlan(capability: req.capability, providerID: providerID,
                                              frameCount: frames.count, hasAudio: !transcript.isEmpty,
                                              fusionModel: fusionModel, meta: meta)
                    cont.yield(.planResolved(plan))
                    cont.yield(.textDelta(answer))
                    cont.yield(.done(finishReason: "stop"))
                    cont.finish()
                } catch is CancellationError {
                    cont.yield(.failed(message: "video understanding was cancelled"))
                    cont.finish(throwing: CancellationError())
                } catch {
                    cont.yield(.failed(message: error.localizedDescription))
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Composition helpers

    static let fusionSystem = """
    You answer questions about a video using SAMPLED keyframe descriptions (with timestamps) and an audio \
    transcript. This is sampled-frame + audio evidence, not a frame-by-frame temporal analysis — do not \
    claim to have seen every moment. Cite timestamps (e.g. "at 0:12") when relevant. If the evidence does \
    not support an answer, say so plainly.
    """

    static func fusionPrompt(question: String, meta: VideoMetadata, captions: [(t: Double, text: String)], transcript: String) -> String {
        func ts(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
        var lines: [String] = []
        lines.append(String(format: "Video: %.1fs, %dx%d%@.", meta.durationSeconds, meta.width, meta.height,
                            meta.codec.map { ", \($0)" } ?? ""))
        lines.append("Sampled keyframes:")
        for c in captions { lines.append("- [\(ts(c.t))] \(c.text)") }
        if captions.isEmpty { lines.append("- (no visual captions available)") }
        lines.append("")
        lines.append("Audio transcript:")
        lines.append(transcript.isEmpty ? "(no speech / no audio)" : transcript)
        lines.append("")
        lines.append("Question: \(question.isEmpty ? "Summarize what happens in this video." : question)")
        return lines.joined(separator: "\n")
    }

    static func buildPlan(capability: CapabilityID, providerID: String, frameCount: Int, hasAudio: Bool,
                          fusionModel: String?, meta: VideoMetadata) -> ExecutionPlan {
        var steps: [ExecutionStep] = [
            ExecutionStep(providerID: "\(providerID)/metadata", backend: .native, consumesOutputOf: nil),
            ExecutionStep(providerID: "\(providerID)/keyframes", backend: .native, consumesOutputOf: 0),
            ExecutionStep(providerID: "image-understand×\(frameCount)", backend: .python, consumesOutputOf: 1)
        ]
        var fusionConsumes = 2
        if hasAudio {
            steps.append(ExecutionStep(providerID: "\(providerID)/audio-extract", backend: .native, consumesOutputOf: 0))
            steps.append(ExecutionStep(providerID: "speech-to-text", backend: .python, consumesOutputOf: steps.count - 1))
            fusionConsumes = steps.count - 1
        }
        steps.append(ExecutionStep(providerID: "language-fuse", modelID: fusionModel, backend: .mlx, consumesOutputOf: fusionConsumes))
        var rationale = [
            "Composed pipeline: native metadata + adaptive keyframe sampling → VLM per frame; " +
            (hasAudio ? "native audio extraction → STT; " : "no audio track; ") +
            "an LLM fuses timestamped captions + transcript to answer.",
            "Sampled \(frameCount) frame(s) over ~\(Int(meta.durationSeconds))s — sampled-frame + audio fusion, not deep temporal understanding."
        ]
        if !hasAudio { rationale.append("Audio/STT step skipped: no usable audio track.") }
        return ExecutionPlan(
            capability: capability,
            inputModalities: [.video, .text],
            outputModality: .text,
            steps: steps,
            rationale: rationale,
            evidenceBacked: false)
    }

    static func stringOption(_ req: ExecutionRequest, _ key: String) -> String? {
        if case .string(let s)? = req.options.values[key] { return s }
        return nil
    }

    /// Strip reasoning tags + special/control tokens that small models leak (e.g. "<start_function_call>",
    /// "<|im_end|>", "<end_of_turn>", "<eos>"), collapse whitespace. Never lets a control-token artifact reach
    /// the user as the answer.
    static func sanitizeFusion(_ raw: String) -> String {
        var s = ThinkingParser.parse(raw).answer ?? raw
        // Angle-bracket special tokens: <...>, <|...|>, <0x..>, and function-call markers.
        s = s.replacingOccurrences(of: #"<\|[^>]*\|>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(start|end)_function_call>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(eos|bos|pad|unk|s|/s|end_of_turn|start_of_turn)>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<0x[0-9A-Fa-f]{2}>"#, with: "", options: .regularExpression)
        // Bare "special-ish" leftover tokens (e.g. "start_function_call", "assistantfinal") at the very start.
        s = s.replacingOccurrences(of: #"^\s*(start_function_call|assistant(final)?|<\|assistant\|>)\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a fusion answer isn't a usable summary: empty, too short, no letters, or a lone leaked token.
    static func isDegenerate(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 12 { return true }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if letters < 8 { return true }                                   // mostly punctuation/tokens
        let words = t.split { $0 == " " || $0 == "\n" }.count
        return words < 3                                                  // not a sentence
    }

    /// Resolve a video attachment to a local file. `uri` file paths used as-is; inline base64 → temp file.
    static func materializeVideo(_ attachment: EshAttachment, into dir: URL) throws -> String {
        if let uri = attachment.uri, !uri.isEmpty {
            let path = uri.hasPrefix("file://") ? URL(string: uri)?.path ?? uri : uri
            guard FileManager.default.fileExists(atPath: path) else {
                throw CapabilityError.failed("video not found at \(path)")
            }
            return path
        }
        guard let b64 = attachment.base64,
              let data = Data(base64Encoded: VisionUnderstandProvider.stripDataURLPrefix(b64)) else {
            throw CapabilityError.failed("video attachment has no readable content")
        }
        let ext: String = {
            switch attachment.mimeType {
            case "video/quicktime": return "mov"
            case "video/x-m4v": return "m4v"
            default: return "mp4"
            }
        }()
        let url = dir.appendingPathComponent("input.\(ext)")
        try data.write(to: url)
        return url.path
    }
}
