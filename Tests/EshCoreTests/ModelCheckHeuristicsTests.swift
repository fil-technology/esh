import Foundation
import Testing
@testable import EshCore

@Test
func infersGGUFFormatArchitectureAndQuantization() {
    let filenames = ["DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"]
    let format = ModelFilenameHeuristics.inferFormat(identifier: "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF", filenames: filenames)
    let architecture = ModelFilenameHeuristics.inferArchitecture(
        identifier: "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF",
        configModelType: nil,
        tags: [],
        filenames: filenames
    )
    let params = ModelFilenameHeuristics.inferParameterCountB(
        identifier: "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF",
        filenames: filenames
    )
    let quant = ModelFilenameHeuristics.inferQuantization(
        identifier: "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF",
        filenames: filenames,
        format: format
    )
    let bits = ModelFilenameHeuristics.inferEffectiveBits(quantization: quant, format: format)

    #expect(format == .gguf)
    #expect(architecture == .qwen)
    #expect(params == 14)
    #expect(quant == "Q4_K_M")
    #expect(bits == 4.5)
}

@Test
func selectsPreferredGGUFFile() {
    let selection = ModelFilenameHeuristics.selectGGUFFiles([
        "model-q5_k_m.gguf",
        "model-q4_k_m.gguf",
        "README.md"
    ])

    #expect(selection.selected == "model-q4_k_m.gguf")
    #expect(selection.related == ["model-q4_k_m.gguf"])
    #expect(selection.warning == nil)
}

@Test
func selectsRequestedGGUFVariant() {
    let selection = ModelFilenameHeuristics.selectGGUFFiles(
        [
            "model-q5_k_m.gguf",
            "model-q4_k_m.gguf",
            "model-q6_k.gguf"
        ],
        variant: "Q5_K_M"
    )

    #expect(selection.selected == "model-q5_k_m.gguf")
    #expect(selection.related == ["model-q5_k_m.gguf"])
    #expect(selection.warning == nil)
}

@Test
func estimatesGGUFMemoryConservatively() throws {
    let estimate = ModelMemoryEstimator().estimate(
        parameterCountB: 14,
        effectiveBits: 4.5,
        quantization: "Q4_K_M",
        contextTokens: 8192,
        format: .gguf
    )

    #expect(estimate.weightsGB == 7.9)
    let runtimeGB = try #require(estimate.runtimeGB)
    #expect(runtimeGB > 9.0)
}

@Test
func supportRegistryRejectsMultimodalGGUF() {
    let assessment = ModelSupportRegistry().assess(
        backend: .gguf,
        format: .gguf,
        architecture: .qwen,
        isMultimodal: true,
        hasSelectedGGUFFile: true
    )

    #expect(assessment.isFormatSupported)
    #expect(!assessment.isArchitectureSupported)
    #expect(assessment.warnings.joined(separator: "\n").contains("text-only"))
}

@Test
func modelCheckResultJSONUsesStableVerdictStrings() throws {
    let result = ModelCheckResult(
        model: "demo",
        backend: .gguf,
        backendLabel: "GGUF (llama.cpp)",
        format: .gguf,
        architecture: .qwen,
        parameterCountB: 14,
        quantization: "Q4_K_M",
        selectedVariant: "Q4_K_M",
        availableVariants: ["Q4_K_M", "Q5_K_M"],
        effectiveBits: 4.5,
        contextTokens: 8192,
        estimatedWeightsGB: 7.9,
        estimatedRuntimeGB: 9.8,
        safeLocalBudgetGB: 22,
        verdict: .supportedAndLikelyFits,
        confidence: 0.9,
        notes: ["heuristic"],
        warnings: [],
        host: HostMachineProfile(safeBudgetGB: 22),
        metadata: ModelMetadata(
            sourceIdentifier: "demo",
            displayName: "demo",
            backend: .gguf,
            format: .gguf,
            architecture: .qwen,
            parameterCountB: 14,
            quantization: "Q4_K_M",
            availableVariants: ["Q4_K_M", "Q5_K_M"],
            selectedVariant: "Q4_K_M",
            effectiveBits: 4.5
        )
    )

    let data = try JSONCoding.encoder.encode(result)
    let text = String(decoding: data, as: UTF8.self)

    #expect(text.contains("\"verdict\" : \"supported_and_likely_fits\""))
    #expect(text.contains("\"backendLabel\" : \"GGUF (llama.cpp)\""))
}
