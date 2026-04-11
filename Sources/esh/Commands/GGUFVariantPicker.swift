import Foundation
import Darwin
import EshCore

enum GGUFVariantPicker {
    static func pick(
        repoID: String,
        metadata: ModelMetadata,
        contextTokens: Int = 4096
    ) async throws -> String {
        guard !metadata.availableVariants.isEmpty else {
            throw StoreError.invalidManifest("No GGUF variants available to choose from.")
        }

        if isatty(STDIN_FILENO) == 0 || isatty(STDOUT_FILENO) == 0 {
            throw StoreError.invalidManifest(
                "Multiple GGUF variants are available for \(repoID): \(metadata.availableVariants.joined(separator: ", ")). Re-run with --variant <name>."
            )
        }

        let items = metadata.availableVariants.map { variant in
            InteractiveListPicker.Item(
                title: variant,
                detail: variantDetail(
                    variant: variant,
                    parameterCountB: metadata.parameterCountB,
                    contextTokens: contextTokens
                )
            )
        }

        let picker = InteractiveListPicker()
        switch picker.pick(
            title: "Choose GGUF Variant",
            subtitle: "Select the quantization variant to install for \(repoID).",
            items: items,
            primaryHint: "Enter install variant"
        ) {
        case .selected(let index):
            return metadata.availableVariants[index]
        default:
            throw StoreError.invalidManifest("Install cancelled.")
        }
    }

    private static func variantDetail(
        variant: String,
        parameterCountB: Double?,
        contextTokens: Int
    ) -> String {
        let effectiveBits = inferEffectiveBits(for: variant)
        let estimate = ModelMemoryEstimator().estimate(
            parameterCountB: parameterCountB,
            effectiveBits: effectiveBits,
            quantization: variant,
            contextTokens: contextTokens,
            format: .gguf
        )

        var parts: [String] = ["GGUF"]
        if let effectiveBits {
            parts.append(String(format: "~%.1f-bit", effectiveBits))
        }
        if let weights = estimate.weightsGB {
            parts.append("~\(formatGB(weights)) weights")
        }
        if let runtime = estimate.runtimeGB {
            parts.append("~\(formatGB(runtime)) runtime")
        }
        if variant.contains("_M") {
            parts.append("balanced")
        } else if variant.contains("_S") {
            parts.append("smaller")
        } else if variant.hasPrefix("Q6") || variant.hasPrefix("Q8") {
            parts.append("higher quality")
        } else if variant.hasPrefix("Q2") || variant.hasPrefix("Q3") || variant.hasPrefix("IQ") {
            parts.append("lighter fit")
        }
        return parts.joined(separator: " | ")
    }

    private static func inferEffectiveBits(for variant: String) -> Double? {
        let normalized = variant.uppercased()
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
        return nil
    }

    private static func formatGB(_ value: Double) -> String {
        String(format: "%.1f GB", value)
    }
}
