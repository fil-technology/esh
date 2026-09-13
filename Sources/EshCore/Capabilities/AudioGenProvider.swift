#if os(macOS)   // esh iOS M1: Python-bridge media/speech provider (MLXBridge/llama aux); macOS-only. See docs/IOS_PORTABILITY_AUDIT.md.
import Foundation

// esh 2.1 UCMR — audio.generate (non-speech SFX / ambience / Foley). Two provider paths behind ONE capability,
// chosen by the scheduler/classifier (proving esh schedules CAPABILITIES, not just models):
//   • DETERMINISTIC DSP — white/pink/brown noise, tones, sweeps, silence. Exact, tiny, instant, no model.
//   • NEURAL text→audio (AudioGen) — environmental sound the DSP can't synthesize ("rain in a forest").
// Deterministic requests never touch a model; neural requests need the installed AudioGen weights (surfaced
// via Install-and-Resume). Output is a typed .audio AudioArtifact (WAV) with duration/sampleRate/channels.


/// Result of an audio generation (deterministic or neural) — feeds AudioArtifact metadata.
public struct AudioGenResult: Sendable {
    public let seconds: Double, sampleRate: Int, channels: Int
    public let provider: String, model: String, license: String
    /// Resolved model revision (HF snapshot commit hash) when known — provenance.
    public let revision: String?
    /// Peak amplitude (0…1+) of the generated signal BEFORE any limiting, and whether a deterministic
    /// peak-normalization was applied to prevent clipping. Recorded in artifact provenance.
    public let peak: Double?, normalized: Bool
    public init(seconds: Double, sampleRate: Int, channels: Int, provider: String, model: String, license: String,
                revision: String? = nil, peak: Double? = nil, normalized: Bool = false) {
        self.seconds = seconds; self.sampleRate = sampleRate; self.channels = channels
        self.provider = provider; self.model = model; self.license = license
        self.revision = revision; self.peak = peak; self.normalized = normalized
    }
}

/// Shared: build the typed .audio AudioArtifact + validate the WAV before success.
enum AudioArtifactComposer {
    static func validateWAV(_ bytes: Data, expectedSeconds: Double) -> ArtifactValidation {
        var f: [String] = []
        if bytes.count < 44 { return ArtifactValidation(isValid: false, findings: ["output too small to be a WAV"]) }
        if bytes.prefix(4) != Data("RIFF".utf8) || bytes.subdata(in: 8..<12) != Data("WAVE".utf8) {
            f.append("not a RIFF/WAVE container")
        }
        // sampleRate @24, channels @22, bitsPerSample @34, dataBytes after "data".
        func u32(_ o: Int) -> UInt32 { bytes.subdata(in: o..<o+4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian } }
        func u16(_ o: Int) -> UInt16 { bytes.subdata(in: o..<o+2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian } }
        let sr = Int(u32(24)), ch = Int(u16(22)), bits = Int(u16(34))
        let dataBytes = bytes.count - 44
        let frames = bits > 0 && ch > 0 ? dataBytes / (ch * bits / 8) : 0
        let actual = sr > 0 ? Double(frames) / Double(sr) : 0
        if frames == 0 { f.append("no audio frames (silent/empty)") }
        if expectedSeconds > 0, abs(actual - expectedSeconds) > max(0.25, expectedSeconds * 0.1) {
            f.append(String(format: "duration %.2fs differs from requested %.2fs", actual, expectedSeconds))
        }
        // Non-silence check: at least one non-zero sample (skip for explicit silence requests).
        let hasSound = bytes.suffix(dataBytes).contains { $0 != 0 }
        return ArtifactValidation(isValid: f.isEmpty && frames > 0, findings: f + (hasSound ? [] : ["effectively silent"]))
    }
}

/// audio.generate — SFX / ambience / Foley. Deterministic DSP for exact waveforms; neural (AudioGen) otherwise.
public struct AudioGenProvider: CapabilityProvider {
    public typealias NeuralFn = @Sendable (_ prompt: String, _ outPath: String, _ seconds: Double, _ seed: Int,
                                           _ sampleRate: Int, _ minFreeMemMB: Int?, _ hfCache: String?) throws -> AudioGenResult
    public let descriptor: CapabilityProviderDescriptor
    private let neural: NeuralFn?

    public init(id: String = "audio-generate", neural: NeuralFn? = nil) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.audioGenerate], acceptedInputs: [.text], producedOutputs: [.audio],
            backend: .native, streaming: false, structuredOutput: false, requiredPrivilege: .artifactOnly)
        self.neural = neural
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AudioGenRunner.run(request: request, context: context, providerID: descriptor.id,
                           capability: .audioGenerate, neural: neural, allowDeterministic: true)
    }
}

/// music.generate — musical compositions / loops / scores. Neural only (MusicGen). Distinct from audio.generate.
public struct MusicGenProvider: CapabilityProvider {
    public typealias NeuralFn = AudioGenProvider.NeuralFn
    public let descriptor: CapabilityProviderDescriptor
    private let neural: NeuralFn?

    public init(id: String = "music-generate", neural: NeuralFn? = nil) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.musicGenerate], acceptedInputs: [.text], producedOutputs: [.audio],
            backend: .python, streaming: false, structuredOutput: false, requiredPrivilege: .artifactOnly)
        self.neural = neural
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AudioGenRunner.run(request: request, context: context, providerID: descriptor.id,
                           capability: .musicGenerate, neural: neural, allowDeterministic: false)
    }
}

/// Shared execution: parse the request, dispatch deterministic-or-neural, validate, emit an AudioArtifact.
enum AudioGenRunner {
    static func run(request: ResolvedExecutionRequest, context: ExecutionContext, providerID: String,
                    capability: CapabilityID, neural: AudioGenProvider.NeuralFn?, allowDeterministic: Bool)
        -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        return AsyncThrowingStream { cont in
            let task = Task {
                var tempPaths: [String] = []
                defer { for p in tempPaths { try? FileManager.default.removeItem(atPath: p) } }
                do {
                    let prompt = req.inputs.compactMap { i -> String? in
                        if case .text(let t) = i.payload { return t }; return nil
                    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !prompt.isEmpty else { throw CapabilityError.failed("audio generation requires a text prompt") }
                    // Point the bridge at the isolated engine venv wherever the user's storage put it (assets
                    // root, internal or external) — the main bridge inherits this env and passes it to the
                    // isolated SFX worker. Legacy fixed paths still resolve for pre-2.3 installs.
                    GenerativeEngineManager(root: context.root).exportInstalledEngineEnvironment()

                    let sampleRate = TextToSVGProvider.intOption(req, "sampleRate") ?? 44100
                    let channels = TextToSVGProvider.intOption(req, "channels") ?? 1
                    let seed = TextToSVGProvider.intOption(req, "seed") ?? 0
                    // Requested duration NEVER silently shortened — parsed from prompt or an explicit option.
                    let seconds = (TextToSVGProvider.intOption(req, "seconds").map(Double.init))
                        ?? DeterministicAudio.duration(prompt)

                    try FileManager.default.createDirectory(at: context.root.tempURL, withIntermediateDirectories: true)
                    let outPath = context.root.tempURL.appendingPathComponent("gen-\(UUID().uuidString).wav").path
                    tempPaths.append(outPath)

                    var result: AudioGenResult
                    if allowDeterministic, let kind = DeterministicAudio.classify(prompt) {
                        cont.yield(.status("synthesizing \(kind.rawValue) (deterministic DSP)"))
                        let freq = DeterministicAudio.frequency(prompt)
                        let mono = DeterministicAudio.samples(kind, seconds: seconds, sampleRate: sampleRate,
                                                              seed: UInt64(bitPattern: Int64(seed)), frequency: freq)
                        let wav = DeterministicAudio.wav(mono, sampleRate: sampleRate, channels: channels)
                        try wav.write(to: URL(fileURLWithPath: outPath))
                        result = AudioGenResult(seconds: seconds, sampleRate: sampleRate, channels: channels,
                                                provider: "deterministic-dsp", model: "esh.dsp.\(kind.rawValue)", license: "none")
                    } else {
                        guard let neural else {
                            throw CapabilityError.failed("no \(capability.rawValue) model is installed for this request")
                        }
                        try StorageService().ensureAssetsAvailable(root: context.root)
                        cont.yield(.status(capability == .musicGenerate ? "composing music" : "generating sound"))
                        let hfCache = context.root.cachesURL.appendingPathComponent("audio-models", isDirectory: true).path
                        let minFree = TextToSVGProvider.intOption(req, "minFreeMemMB")
                        result = try neural(prompt, outPath, seconds, seed, sampleRate, minFree, hfCache)
                    }
                    if Task.isCancelled { throw CancellationError() }

                    let bytes = try Data(contentsOf: URL(fileURLWithPath: outPath))
                    let validation = AudioArtifactComposer.validateWAV(bytes, expectedSeconds: result.seconds)
                    var meta: [String: JSONValue] = [
                        "durationSeconds": .double((validation.isValid ? result.seconds : 0)),
                        "sampleRate": .int(result.sampleRate), "channels": .int(result.channels),
                        "byteSize": .int(bytes.count), "prompt": .string(prompt), "seed": .int(seed),
                        "provider": .string(result.provider), "model": .string(result.model), "license": .string(result.license),
                        "format": .string("wav"), "normalized": .bool(result.normalized)]
                    if let peak = result.peak { meta["peak"] = .double(peak) }   // pre-limiter peak amplitude
                    if let rev = result.revision { meta["revision"] = .string(rev) }
                    let artifact = Artifact(
                        kind: .audio, mimeType: "audio/wav", entrypoint: "result.wav", metadata: meta,
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: result.model, capability: capability),
                        validation: validation, preview: PreviewDescriptor(mode: .none, privilege: .artifactOnly))
                    let saved = try context.artifactStore.save(artifact, files: ["result.wav": bytes])
                    let isDSP = result.provider == "deterministic-dsp"
                    cont.yield(.planResolved(ExecutionPlan.single(
                        capability: capability, inputModalities: [.text], outputModality: .audio,
                        providerID: providerID, modelID: result.model, backend: isDSP ? .native : .python,
                        rationale: [isDSP
                            ? "Exact waveform — deterministic DSP is smaller, faster and exact; no model needed."
                            : "Environmental/musical audio the DSP can't synthesize — routed to the \(result.model) model."])))
                    cont.yield(.artifactProduced(saved))
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// Bridges the neural audio backends (AudioGen for sound, MusicGen for music) through the RAM-guarded MLX
/// bridge. Model weights download to the assets root (SSD) on first use; throws clearly when unavailable.
public struct AudioGenService: Sendable {
    public enum Kind: String, Sendable { case sound, music }
    private let bridge: MLXBridge
    public init(bridge: MLXBridge = .init()) { self.bridge = bridge }

    @discardableResult
    public func generate(kind: Kind, prompt: String, outputPath: String, seconds: Double, seed: Int,
                         sampleRate: Int, minFreeMemMB: Int?, hfCache: String?) throws -> AudioGenResult {
        let r: Response = try bridge.runCancellable(
            command: kind == .music ? "music-generate" : "audio-generate",
            request: Request(prompt: prompt, outputPath: outputPath, seconds: seconds, seed: seed,
                             sampleRate: sampleRate, minFreeMemMB: minFreeMemMB, hfCache: hfCache),
            as: Response.self)
        return AudioGenResult(seconds: r.seconds, sampleRate: r.sampleRate, channels: r.channels,
                              provider: r.provider, model: r.model, license: r.license,
                              revision: r.revision, peak: r.peak, normalized: r.normalized ?? false)
    }
    private struct Request: Codable, Sendable {
        let prompt: String; let outputPath: String; let seconds: Double; let seed: Int
        let sampleRate: Int; let minFreeMemMB: Int?; let hfCache: String?
    }
    private struct Response: Codable, Sendable {
        let outputPath: String; let seconds: Double; let sampleRate: Int; let channels: Int
        let provider: String; let model: String; let license: String
        let revision: String?; let peak: Double?; let normalized: Bool?
    }
}

#endif
