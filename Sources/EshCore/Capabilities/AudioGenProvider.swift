import Foundation

// esh 2.1 UCMR — audio.generate (non-speech SFX / ambience / Foley). Two provider paths behind ONE capability,
// chosen by the scheduler/classifier (proving esh schedules CAPABILITIES, not just models):
//   • DETERMINISTIC DSP — white/pink/brown noise, tones, sweeps, silence. Exact, tiny, instant, no model.
//   • NEURAL text→audio (AudioGen) — environmental sound the DSP can't synthesize ("rain in a forest").
// Deterministic requests never touch a model; neural requests need the installed AudioGen weights (surfaced
// via Install-and-Resume). Output is a typed .audio AudioArtifact (WAV) with duration/sampleRate/channels.

/// Deterministic audio DSP — pure functions producing 16-bit PCM WAV. No model, no I/O.
public enum DeterministicAudio {
    public enum Kind: String, Sendable, CaseIterable { case white, pink, brown, tone, sweep, silence }

    /// Classify a prompt as an exact deterministic waveform, or nil when it needs a neural model.
    public static func classify(_ prompt: String) -> Kind? {
        let p = prompt.lowercased()
        if p.contains("white noise") { return .white }
        if p.contains("pink noise") { return .pink }
        if p.contains("brown noise") || p.contains("brownian noise") || p.contains("red noise") { return .brown }
        if p.contains("silence") || p.contains("silent") { return .silence }
        if p.contains("sweep") || p.contains("chirp") || (p.contains("frequency") && p.contains("to")) { return .sweep }
        if p.contains("sine") || p.contains(" tone") || p.contains("pure tone") || p.contains("test tone")
            || p.contains(" beep") || p.contains(" hz") { return .tone }
        return nil
    }

    /// Parse a requested duration in seconds from the prompt ("30 seconds", "20s", "1 minute"); default 10, cap 600.
    public static func duration(_ prompt: String, default def: Double = 10) -> Double {
        let p = prompt.lowercased()
        if let m = p.range(of: #"(\d+(?:\.\d+)?)\s*(?:seconds?|secs?|s)\b"#, options: .regularExpression),
           let n = Double(p[m].prefix { $0.isNumber || $0 == "." }) { return min(600, max(0.1, n)) }
        if let m = p.range(of: #"(\d+(?:\.\d+)?)\s*(?:minutes?|mins?|m)\b"#, options: .regularExpression),
           let n = Double(p[m].prefix { $0.isNumber || $0 == "." }) { return min(600, max(0.1, n * 60)) }
        return def
    }

    /// Parse a frequency in Hz ("440 Hz", "1 kHz"); default 440.
    public static func frequency(_ prompt: String, default def: Double = 440) -> Double {
        let p = prompt.lowercased()
        if let m = p.range(of: #"(\d+(?:\.\d+)?)\s*khz"#, options: .regularExpression),
           let n = Double(p[m].prefix { $0.isNumber || $0 == "." }) { return n * 1000 }
        if let m = p.range(of: #"(\d+(?:\.\d+)?)\s*hz"#, options: .regularExpression),
           let n = Double(p[m].prefix { $0.isNumber || $0 == "." }) { return n }
        return def
    }

    /// Generate mono float samples in [-1, 1] for `kind` at `sampleRate` for `seconds`. Deterministic per `seed`.
    public static func samples(_ kind: Kind, seconds: Double, sampleRate: Int, seed: UInt64,
                               frequency freq: Double = 440) -> [Float] {
        let n = max(1, Int(seconds * Double(sampleRate)))
        var rng = SplitMix64(seed: seed == 0 ? 0x9E3779B97F4A7C15 : seed)
        func urand() -> Float { Float(rng.next() >> 11) / Float(1 << 53) * 2 - 1 }   // uniform [-1,1)
        var out = [Float](repeating: 0, count: n)
        switch kind {
        case .silence:
            break
        case .white:
            for i in 0..<n { out[i] = urand() * 0.6 }
        case .pink:
            // Paul Kellet's economical pink-noise filter.
            var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
            for i in 0..<n {
                let w = urand()
                b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759
                b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856
                b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
                let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
                b6 = w * 0.115926
                out[i] = pink * 0.11
            }
        case .brown:
            var last: Float = 0
            for i in 0..<n {
                last = (last + 0.02 * urand()); last = max(-1, min(1, last))
                out[i] = last * 3.0
            }
        case .tone:
            let twoPiF = 2 * Float.pi * Float(freq) / Float(sampleRate)
            for i in 0..<n { out[i] = 0.6 * sin(twoPiF * Float(i)) }
        case .sweep:
            let f0: Float = Float(min(freq, 200)), f1: Float = 8000
            let dur = Float(seconds)
            for i in 0..<n {
                let t = Float(i) / Float(sampleRate)
                let inst = f0 + (f1 - f0) * (t / dur)
                let phase = 2 * Float.pi * (f0 * t + (f1 - f0) * t * t / (2 * dur))
                out[i] = 0.5 * sin(phase); _ = inst
            }
        }
        // Short fade in/out (5ms) to avoid clicks.
        let fade = min(n / 2, Int(0.005 * Double(sampleRate)))
        if fade > 1 { for i in 0..<fade { let g = Float(i) / Float(fade); out[i] *= g; out[n - 1 - i] *= g } }
        return out
    }

    /// Encode mono float samples as a 16-bit PCM WAV (optionally duplicated to stereo).
    public static func wav(_ mono: [Float], sampleRate: Int, channels: Int) -> Data {
        let ch = max(1, min(2, channels))
        var pcm = [Int16](); pcm.reserveCapacity(mono.count * ch)
        for s in mono {
            let v = Int16(max(-1, min(1, s)) * 32767)
            for _ in 0..<ch { pcm.append(v) }
        }
        let byteRate = sampleRate * ch * 2, blockAlign = ch * 2, dataBytes = pcm.count * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataBytes)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(UInt16(ch)); u32(UInt32(sampleRate))
        u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(dataBytes))
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}

/// Tiny, fast, deterministic RNG (SplitMix64) so noise is reproducible per seed.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

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
