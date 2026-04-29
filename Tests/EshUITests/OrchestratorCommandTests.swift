import Foundation
import Testing
import EshCore
@testable import esh

@Suite
struct OrchestratorCommandTests {
    @Test
    func enginesListOutputShowsRequiredAndOptionalEngines() {
        let lines = EnginesCommand.listLines(results: [
            EngineDetectionResult(
                engine: .llamaCpp,
                installed: true,
                status: .ready,
                isOptional: false,
                platformCompatible: true,
                binaryPath: "/opt/homebrew/bin/llama-cli",
                acceleration: .available("Metal"),
                formats: [.gguf],
                capabilities: ["GGUF", "Metal"]
            ),
            EngineDetectionResult(
                engine: .ollama,
                installed: false,
                status: .missing,
                isOptional: true,
                platformCompatible: true,
                formats: [],
                capabilities: ["External adapter"]
            )
        ])

        #expect(lines.contains("llama.cpp   installed   ready      required   GGUF, Metal"))
        #expect(lines.contains("Ollama      missing     missing    optional   External adapter"))
    }

    @Test
    func validateCommandOutputIncludesSelectedEngineAndMissingDependencies() {
        let report = ModelValidationReport(
            modelID: "qwen3",
            displayName: "Qwen3",
            localPath: "/tmp/qwen3",
            detectedFormat: .mlx,
            foundFiles: ["config.json", "model.safetensors"],
            compatibleEngines: [.mlx],
            selectedEngine: .mlx,
            selectedBackend: .mlx,
            selectionExplanation: "MLX format detected on Apple Silicon.",
            missingDependencies: [],
            suggestedFixes: [],
            warnings: [],
            sizeBytes: 1_073_741_824
        )

        let lines = ValidateCommand.outputLines(report: report)

        #expect(lines.contains("Model: qwen3"))
        #expect(lines.contains("Format: MLX"))
        #expect(lines.contains("Selected engine: MLX"))
        #expect(lines.contains("Decision: MLX format detected on Apple Silicon."))
    }

    @Test
    func configShowIncludesPathAndExperimentalFlags() {
        let url = URL(fileURLWithPath: "/tmp/esh/config.toml")
        let text = ConfigCommand.showText(
            configuration: OrchestratorConfiguration(
                experimental: .init(ollamaAdapter: true, llamaCppServer: true)
            ),
            configURL: url
        )

        #expect(text.contains("path: /tmp/esh/config.toml"))
        #expect(text.contains("ollama_adapter = true"))
        #expect(text.contains("llama_cpp_server = true"))
    }
}
