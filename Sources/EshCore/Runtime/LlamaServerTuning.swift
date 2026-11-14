import Foundation

/// EXPERIMENTAL, opt-in llama-server tuning for esh's GGUF backend (off unless an environment variable sets it).
///
/// llama.cpp b8660 (esh's pin) already ships prompt-lookup ("n-gram") speculative decoding and quantized KV caches;
/// esh simply never passed the flags. Measured through esh's own llama-server arguments on an M1 Pro (see
/// docs/research/ghost-infer-2026-11/D-benchmark-report.md): `ngram-simple` speeds whole-file code edits ~3.4x on
/// Qwen2.5-1.5B Q4_K_M with byte-identical output, and is neutral on chat. Values are ALLOW-LISTED — nothing from
/// the environment is passed to the process verbatim.
///
///   ESH_LLAMA_SPEC_TYPE = ngram-simple | ngram-mod | ngram-map-k | ngram-map-k4v | ngram-cache
///   ESH_LLAMA_DRAFT_MAX = 1…64           (llama.cpp default 16)
///   ESH_LLAMA_KV_TYPE   = f16 | q8_0 | q4_0   (K and V; trades decode speed for KV memory)
public struct LlamaServerTuning: Sendable, Equatable {
    public enum SpeculativeType: String, Sendable, CaseIterable {
        /// Drafts from the current request's context only (stateless). The recommended mode.
        case ngramSimple = "ngram-simple"
        /// Keeps an n-gram pool ACROSS requests in the server process (it can replay earlier answers).
        case ngramMod = "ngram-mod"
        case ngramMapK = "ngram-map-k"
        case ngramMapK4V = "ngram-map-k4v"
        case ngramCache = "ngram-cache"
    }

    public enum KVCacheType: String, Sendable, CaseIterable {
        case f16, q8_0, q4_0
    }

    public var speculative: SpeculativeType?
    public var draftMax: Int?
    public var kvCacheType: KVCacheType?

    public init(speculative: SpeculativeType? = nil, draftMax: Int? = nil, kvCacheType: KVCacheType? = nil) {
        self.speculative = speculative
        self.draftMax = draftMax.map { min(max($0, 1), 64) }
        self.kvCacheType = kvCacheType
    }

    /// No extra flags: esh's long-standing llama-server invocation.
    public static let `default` = LlamaServerTuning()

    public var isDefault: Bool { self == .default }

    /// Parse the opt-in environment variables. Unknown or out-of-range values are ignored (→ default behaviour).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LlamaServerTuning {
        let spec = environment["ESH_LLAMA_SPEC_TYPE"].flatMap { SpeculativeType(rawValue: $0.lowercased()) }
        let draft = environment["ESH_LLAMA_DRAFT_MAX"].flatMap { Int($0) }.flatMap { (1...64).contains($0) ? $0 : nil }
        let kv = environment["ESH_LLAMA_KV_TYPE"].flatMap { KVCacheType(rawValue: $0.lowercased()) }
        return LlamaServerTuning(speculative: spec, draftMax: spec == nil ? nil : draft, kvCacheType: kv)
    }

    /// Extra `llama-server` arguments (appended after esh's base arguments).
    public var arguments: [String] {
        var args: [String] = []
        if let speculative {
            args += ["--spec-type", speculative.rawValue]
            if let draftMax { args += ["--draft-max", String(draftMax)] }
        }
        if let kvCacheType {
            args += ["-ctk", kvCacheType.rawValue, "-ctv", kvCacheType.rawValue]
        }
        return args
    }

    /// Known caveats for the selected settings (surfaced in logs/diagnostics, never silently).
    public var warnings: [String] {
        var notes: [String] = []
        switch speculative {
        case .ngramMapK, .ngramMapK4V:
            notes.append("llama-server b8660 crashed mid-request with --spec-type ngram-map-k in esh's benchmark; prefer ngram-simple")
        case .ngramMod, .ngramCache:
            notes.append("\(speculative!.rawValue) keeps n-gram state across requests: repeated prompts replay earlier answers faster, which inflates benchmarks")
        default:
            break
        }
        if let kvCacheType, kvCacheType != .f16 {
            notes.append("quantized KV (\(kvCacheType.rawValue)) lowers decode speed at short context on Apple Silicon (-13…-20% measured); use it only to fit long contexts")
        }
        return notes
    }
}
