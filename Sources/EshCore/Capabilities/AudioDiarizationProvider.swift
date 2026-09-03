import Foundation

// esh 2.1 UCMR, Stage 3 — speaker diarization (audio → structured). Labels anonymous speaker CLUSTERS
// (speaker_0, speaker_1, …) with time ranges via sherpa-onnx (onnxruntime, torch-free); optionally merges
// an STT transcript. HONEST SCOPE: this is clustering, NOT speaker-identity recognition — no names are
// inferred. sherpa-onnx + its two small models are an optional dependency.

public struct DiarizationSegment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public init(start: Double, end: Double, speaker: String) {
        self.start = start; self.end = end; self.speaker = speaker
    }
}

public struct DiarizationService: Sendable {
    private let bridge: MLXBridge
    public init(bridge: MLXBridge = .init()) { self.bridge = bridge }

    public func diarize(audioPath: String, segModel: String, embModel: String, numSpeakers: Int?, clusterThreshold: Double?) throws -> [DiarizationSegment] {
        let response: Response = try bridge.run(
            command: "audio-diarize",
            request: Request(audioPath: audioPath, segModel: segModel, embModel: embModel,
                             numSpeakers: numSpeakers, clusterThreshold: clusterThreshold),
            as: Response.self)
        return response.segments
    }

    private struct Request: Codable, Sendable {
        let audioPath: String; let segModel: String; let embModel: String
        let numSpeakers: Int?; let clusterThreshold: Double?
    }
    private struct Response: Codable, Sendable { let segments: [DiarizationSegment]; let speakers: Int }
}

public struct AudioDiarizationProvider: CapabilityProvider {
    public typealias DiarizeFn = @Sendable (_ audioPath: String, _ numSpeakers: Int?) async throws -> [DiarizationSegment]
    public typealias TranscribeFn = @Sendable (_ audioPath: String) async throws -> String

    public let descriptor: CapabilityProviderDescriptor
    private let diarize: DiarizeFn
    private let transcribe: TranscribeFn?

    public init(id: String = "audio-diarization", diarize: @escaping DiarizeFn, transcribe: TranscribeFn? = nil) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.audioDiarize],
            acceptedInputs: [.audio],
            producedOutputs: [.json],
            backend: .python,
            streaming: false,
            structuredOutput: true,
            requiredPrivilege: .artifactOnly,
            previewMode: .none)
        self.diarize = diarize
        self.transcribe = transcribe
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let diarize = self.diarize
        let transcribe = self.transcribe
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                var tempPaths: [String] = []
                defer { for p in tempPaths { try? FileManager.default.removeItem(atPath: p) } }
                do {
                    guard let audio = req.inputs.compactMap({ input -> EshAttachment? in
                        if case .attachment(let a) = input.payload, a.kind == .audio { return a }
                        return nil
                    }).first else {
                        throw CapabilityError.failed("diarization requires an audio input")
                    }
                    let (audioPath, isTemp) = try VisionUnderstandProvider.materialize(audio, root: context.root)
                    if isTemp { tempPaths.append(audioPath) }
                    let numSpeakers = TextToSVGProvider.intOption(req, "numSpeakers")
                    let wantTranscript = Self.boolOption(req, "withTranscript") ?? (transcribe != nil)

                    cont.yield(.status("diarizing speakers"))
                    let segments = try await diarize(audioPath, numSpeakers)
                    try Task.checkCancellation()

                    var transcript: String?
                    var steps = [ExecutionStep(providerID: providerID, backend: .python, consumesOutputOf: nil)]
                    if wantTranscript, let transcribe {
                        cont.yield(.status("transcribing"))
                        transcript = try? await transcribe(audioPath)
                        steps.append(ExecutionStep(providerID: "speech-to-text", backend: .python, consumesOutputOf: nil))
                    }

                    let speakers = Set(segments.map { $0.speaker }).count
                    let payload = DiarizationResult(speakers: speakers, segments: segments, transcript: transcript,
                                                    note: "Speaker labels are anonymous clusters, not identities.")
                    let json = String(decoding: (try? JSONCoding.encoder.encode(payload)) ?? Data("{}".utf8), as: UTF8.self)

                    let plan = ExecutionPlan(
                        capability: req.capability, inputModalities: [.audio], outputModality: .json, steps: steps,
                        rationale: [
                            "Diarization clusters speakers by embedding similarity (sherpa-onnx) — anonymous clusters, not identities."
                        ] + (transcript != nil ? ["STT transcript attached (not word-aligned to speakers)."] : []),
                        evidenceBacked: false)
                    cont.yield(.planResolved(plan))
                    cont.yield(.textDelta(json))
                    cont.yield(.done(finishReason: "stop"))
                    cont.finish()
                } catch is CancellationError {
                    cont.yield(.failed(message: "diarization was cancelled"))
                    cont.finish(throwing: CancellationError())
                } catch {
                    cont.yield(.failed(message: error.localizedDescription))
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    struct DiarizationResult: Codable, Sendable {
        var speakers: Int
        var segments: [DiarizationSegment]
        var transcript: String?
        var note: String
    }

    static func boolOption(_ req: ExecutionRequest, _ key: String) -> Bool? {
        if case .bool(let b)? = req.options.values[key] { return b }
        return nil
    }
}
