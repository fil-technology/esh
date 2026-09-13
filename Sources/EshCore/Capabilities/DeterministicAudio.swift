import Foundation

// Deterministic audio DSP + RNG. Extracted from AudioGenProvider (esh iOS M1): pure, model-free
// WAV synthesis used by portable routing (IntentResolver). No platform dependency.

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
