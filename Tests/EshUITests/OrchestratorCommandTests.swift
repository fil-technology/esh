import Foundation
import Testing
import EshCore
@testable import esh

@Suite
struct OrchestratorCommandTests {
    @Test
    func configCommandPrintsPathAndDefaultConfig() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())

        let pathLines = try ConfigCommand.outputLines(arguments: ["path"], root: root)
        #expect(pathLines == [root.rootURL.appendingPathComponent("config.toml").path])

        let showLines = try ConfigCommand.outputLines(arguments: ["show"], root: root)
        #expect(showLines.joined(separator: "\n").contains("[engines.llama_cpp]"))
    }

    @Test
    func enginesListIncludesRequiredAndOptionalEngines() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let service = EngineOrchestratorService(
            root: root,
            environment: ["PATH": ""],
            mlxDoctor: CommandStaticMLXPackageDoctor.failure("not checked"),
            defaultSearchPaths: []
        )

        let lines = try EnginesCommand.outputLines(arguments: ["list"], root: root, service: service)

        #expect(lines.joined(separator: "\n").contains("llama.cpp"))
        #expect(lines.joined(separator: "\n").contains("mlx"))
        #expect(lines.joined(separator: "\n").contains("ollama"))
        #expect(lines.joined(separator: "\n").contains("optional"))
    }

    @Test
    func validateCommandCanRenderJSONReport() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let modelURL = root.rootURL.appendingPathComponent("demo.gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        let service = LocalModelValidationService(engineService: EngineOrchestratorService(
            root: root,
            environment: ["PATH": ""],
            mlxDoctor: CommandStaticMLXPackageDoctor.failure("not checked"),
            defaultSearchPaths: []
        ))

        let lines = try ValidateCommand.outputLines(
            arguments: [modelURL.path, "--json"],
            root: root,
            service: service
        )

        let text = lines.joined(separator: "\n")
        #expect(text.contains(#""format" : "gguf""#))
        #expect(text.contains(#""compatibleEngines" : ["#))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct CommandStaticMLXPackageDoctor: MLXPackageDoctor {
    let message: String?

    static func failure(_ message: String) -> CommandStaticMLXPackageDoctor {
        CommandStaticMLXPackageDoctor(message: message)
    }

    func check() throws -> MLXPackageDoctorReport {
        if let message {
            throw StoreError.invalidManifest(message)
        }
        return MLXPackageDoctorReport(
            pythonExecutable: "/tmp/python",
            mlxVersion: "0.26.0",
            mlxLMVersion: "0.25.0",
            mlxVLMVersion: "0.5.0",
            numpyVersion: "2.0.0",
            safetensorsVersion: "0.5.0"
        )
    }
}
