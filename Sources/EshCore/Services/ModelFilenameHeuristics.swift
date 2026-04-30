import Foundation

enum ModelFilenameHeuristics {
    static func inferFormat(identifier: String, filenames: [String]) -> ModelFormat {
        let loweredFiles = filenames.map { $0.lowercased() }
        if loweredFiles.contains(where: { $0.hasSuffix(".gguf") }) {
            return .gguf
        }
        let loweredIdentifier = identifier.lowercased()
        if loweredIdentifier.contains("gguf") {
            return .gguf
        }

        let hasSafetensors = loweredFiles.contains { $0.hasSuffix(".safetensors") }
        let hasModelConfig = loweredFiles.contains { $0 == "config.json" || $0.hasSuffix("/config.json") }
        let hasAdapterConfig = loweredFiles.contains { $0 == "adapter_config.json" || $0.hasSuffix("/adapter_config.json") }
        if hasSafetensors && (hasModelConfig || hasAdapterConfig) {
            return .mlx
        }
        if loweredIdentifier.contains("mlx") || loweredIdentifier.contains("4bit") {
            return .mlx
        }
        return .unknown
    }

    static func inferAdapter(
        identifier: String,
        tags: [String],
        filenames: [String],
        libraryName: String? = nil
    ) -> Bool {
        let haystacks = ([identifier, libraryName] + tags + filenames)
            .compactMap { $0?.lowercased() }
        return haystacks.contains {
            $0 == "peft"
                || $0 == "lora"
                || $0.contains("adapter_config.json")
                || $0.contains("adapter_model.safetensors")
                || $0.contains("base_model:adapter:")
        }
    }

    static func inferBaseModelID(tags: [String]) -> String? {
        for tag in tags {
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = normalized.lowercased()
            if lowered.hasPrefix("base_model:adapter:") {
                return String(normalized.dropFirst("base_model:adapter:".count))
            }
            if lowered.hasPrefix("base_model:") {
                return String(normalized.dropFirst("base_model:".count))
            }
        }
        return nil
    }

    static func inferArchitecture(
        identifier: String,
        configModelType: String?,
        tags: [String],
        filenames: [String]
    ) -> ModelArchitecture {
        let haystacks = ([identifier, configModelType] + tags + filenames)
            .compactMap { $0?.lowercased() }

        if haystacks.contains(where: { $0.contains("qwen") }) {
            return .qwen
        }
        if haystacks.contains(where: { $0.contains("gemma") }) {
            return .gemma
        }
        if haystacks.contains(where: { $0.contains("mistral") || $0.contains("mixtral") }) {
            return .mistral
        }
        if haystacks.contains(where: { $0.contains("phi") }) {
            return .phi
        }
        if haystacks.contains(where: { $0.contains("llama") || $0.contains("mllama") || $0.contains("deepseek-r1-distill-llama") }) {
            return .llama
        }
        return configModelType == nil && filenames.isEmpty ? .unknown : .other
    }

    static func inferParameterCountB(identifier: String, filenames: [String]) -> Double? {
        for candidate in [identifier] + filenames {
            if let value = firstMatch(in: candidate, pattern: #"(?i)(?:^|[-_])(\d+(?:\.\d+)?)b(?:[-_]|$)"#) {
                return Double(value)
            }
            if let value = firstMatch(in: candidate, pattern: #"(?i)(?:^|[-_])(\d+(?:\.\d+)?)m(?:[-_]|$)"#),
               let millions = Double(value) {
                return millions / 1_000
            }
        }
        return nil
    }

    static func inferQuantization(identifier: String, filenames: [String], format: ModelFormat) -> String? {
        for candidate in filenames + [identifier] {
            if let quant = extractGGUFQuant(from: candidate), format == .gguf {
                return quant
            }
            if let bits = firstMatch(in: candidate, pattern: #"(?i)(\d+(?:\.\d+)?)\s*bit"#) {
                return "\(bits)-bit"
            }
            if let fp = firstMatch(in: candidate, pattern: #"(?i)\b(fp16|bf16|fp8|int8)\b"#) {
                return fp.uppercased()
            }
        }
        return nil
    }

    static func inferEffectiveBits(quantization: String?, format: ModelFormat) -> Double? {
        guard let quantization else { return nil }
        let normalized = quantization.uppercased()
        if format == .gguf {
            if normalized.contains("IQ") {
                if normalized.contains("1") { return 1.75 }
                if normalized.contains("2") { return 2.5 }
                if normalized.contains("3") { return 3.35 }
                if normalized.contains("4") { return 4.25 }
            }
            if normalized.contains("Q2") { return 2.64 }
            if normalized.contains("Q3") { return 3.44 }
            if normalized.contains("Q4") { return 4.5 }
            if normalized.contains("Q5") { return 5.52 }
            if normalized.contains("Q6") { return 6.56 }
            if normalized.contains("Q8") { return 8.0 }
        }
        if normalized == "BF16" || normalized == "FP16" {
            return 16
        }
        if normalized == "FP8" || normalized == "INT8" {
            return 8
        }
        if let bits = firstMatch(in: normalized, pattern: #"(\d+(?:\.\d+)?)"#) {
            return Double(bits)
        }
        return nil
    }

    static func inferMultimodal(
        identifier: String,
        tags: [String],
        configModelType: String?
    ) -> Bool? {
        let haystacks = ([identifier, configModelType] + tags).compactMap { $0?.lowercased() }
        if haystacks.isEmpty {
            return nil
        }
        return haystacks.contains {
            $0.contains("vision")
                || $0.contains("multimodal")
                || $0.contains("image-text")
                || $0.contains("vl")
                || $0.contains("llava")
        }
    }

    static func selectGGUFFiles(_ filenames: [String]) -> (selected: String?, related: [String], isSplit: Bool, warning: String?) {
        let ggufFiles = filenames.filter { $0.lowercased().hasSuffix(".gguf") }.sorted()
        guard !ggufFiles.isEmpty else {
            return (nil, [], false, nil)
        }

        if ggufFiles.count == 1 {
            return (ggufFiles[0], ggufFiles, false, nil)
        }

        let ranked = ggufFiles
            .map { ($0, ggufPreferenceScore(for: $0)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0 < rhs.0
            }

        guard let best = ranked.first else {
            return (nil, ggufFiles, false, "Multiple GGUF files were found and no default candidate could be selected.")
        }

        if ranked.count > 1, ranked[0].1 == ranked[1].1 {
            return (nil, ggufFiles, false, "Multiple GGUF files were found and no obvious default candidate was detected.")
        }

        if let familyPrefix = shardFamilyPrefix(for: best.0) {
            let related = ggufFiles.filter { shardFamilyPrefix(for: $0) == familyPrefix }
            return (best.0, related.sorted(), true, nil)
        }

        return (best.0, [best.0], false, nil)
    }

    static func availableVariants(in filenames: [String], format: ModelFormat) -> [String] {
        guard format == .gguf else { return [] }
        return Array(Set(filenames.compactMap(extractGGUFQuant(from:)))).sorted()
    }

    static func selectGGUFFiles(
        _ filenames: [String],
        variant: String?
    ) -> (selected: String?, related: [String], isSplit: Bool, warning: String?) {
        guard let variant, !variant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return selectGGUFFiles(filenames)
        }

        let normalizedVariant = variant.uppercased()
        if filenames.isEmpty {
            return (nil, [], false, nil)
        }
        let ggufFiles = filenames.filter {
            $0.lowercased().hasSuffix(".gguf") &&
            extractGGUFQuant(from: $0)?.uppercased() == normalizedVariant
        }.sorted()

        guard !ggufFiles.isEmpty else {
            return (
                nil,
                [],
                false,
                "Requested GGUF variant \(normalizedVariant) was not found in this repo."
            )
        }

        if ggufFiles.count == 1 {
            return (ggufFiles[0], ggufFiles, false, nil)
        }

        let ranked = ggufFiles
            .map { ($0, ggufPreferenceScore(for: $0)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0 < rhs.0
            }

        guard let best = ranked.first else {
            return (nil, [], false, "Requested GGUF variant \(normalizedVariant) could not be resolved.")
        }

        if let familyPrefix = shardFamilyPrefix(for: best.0) {
            let related = ggufFiles.filter { shardFamilyPrefix(for: $0) == familyPrefix }
            return (best.0, related.sorted(), true, nil)
        }

        return (best.0, [best.0], false, nil)
    }

    private static func ggufPreferenceScore(for filename: String) -> Int {
        let lowered = filename.lowercased()
        if lowered.contains("q4_k_m") { return 120 }
        if lowered.contains("q4_k_s") { return 110 }
        if lowered.contains("q4_k") { return 100 }
        if lowered.contains("q5_k_m") { return 95 }
        if lowered.contains("q5_k") { return 90 }
        if lowered.contains("q6_k") { return 80 }
        if lowered.contains("iq4") { return 75 }
        if lowered.contains("q3_k") { return 70 }
        if lowered.contains("q2_k") { return 60 }
        if lowered.contains("f16") || lowered.contains("bf16") { return 10 }
        return 50
    }

    private static func shardFamilyPrefix(for filename: String) -> String? {
        guard let range = filename.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) else {
            return nil
        }
        return String(filename[..<range.lowerBound])
    }

    private static func extractGGUFQuant(from candidate: String) -> String? {
        if let match = firstMatch(in: candidate, pattern: #"(?i)\b(iq[1-4](?:_[a-z]+)?|q[2-8](?:_[a-z0-9]+)+)\b"#) {
            return match.uppercased()
        }
        return nil
    }

    private static func firstMatch(in string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: string) else {
            return nil
        }
        return String(string[captureRange])
    }
}
