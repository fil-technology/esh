import Foundation
import Testing
@testable import EshCore

@Suite
struct LocalModelValidationTests {
    @Test
    func validatesGGUFFileAndSelectsReadyLlamaCppEngine() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let fakeLlama = try executable(named: "llama-cli")
        let modelURL = root.rootURL.appendingPathComponent("demo.Q4_K_M.gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        let engines = EngineOrchestratorService(
            root: root,
            environment: [
                "ESH_LLAMA_CPP_CLI": fakeLlama.path,
                "PATH": ""
            ],
            mlxDoctor: StaticMLXPackageDoctor.failure("not checked"),
            defaultSearchPaths: []
        )
        let service = LocalModelValidationService(engineService: engines)

        let report = try service.validate(modelPath: modelURL.path, enginePreference: .auto)

        #expect(report.format == .gguf)
        #expect(report.compatibleEngines == [.llamaCpp])
        #expect(report.readyEngine == .llamaCpp)
        #expect(report.suggestedFixes.isEmpty)
    }

    @Test
    func validatesMLXDirectoryAndSelectsReadyMLXEngine() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let modelURL = root.rootURL.appendingPathComponent("mlx-model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen2"}"#.utf8).write(to: modelURL.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: modelURL.appendingPathComponent("model.safetensors"))
        let engines = EngineOrchestratorService(
            root: root,
            environment: ["PATH": ""],
            mlxDoctor: StaticMLXPackageDoctor.success(),
            defaultSearchPaths: []
        )
        let service = LocalModelValidationService(engineService: engines)

        let report = try service.validate(modelPath: modelURL.path, enginePreference: .auto)

        #expect(report.format == .mlx)
        #expect(report.compatibleEngines == [.mlx])
        #expect(report.readyEngine == .mlx)
    }

    @Test
    func engineFilterReportsIncompatibleRuntime() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let modelURL = root.rootURL.appendingPathComponent("demo.gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        let service = LocalModelValidationService(engineService: EngineOrchestratorService(
            root: root,
            environment: ["PATH": ""],
            mlxDoctor: StaticMLXPackageDoctor.success(),
            defaultSearchPaths: []
        ))

        let report = try service.validate(modelPath: modelURL.path, enginePreference: .mlx)

        #expect(report.format == .gguf)
        #expect(report.compatibleEngines.isEmpty)
        #expect(report.readyEngine == nil)
        #expect(report.warnings.contains { $0.contains("does not support GGUF") })
    }

    @Test
    func missingRequiredEngineIncludesSuggestedFix() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let modelURL = root.rootURL.appendingPathComponent("demo.gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        let service = LocalModelValidationService(engineService: EngineOrchestratorService(
            root: root,
            environment: ["PATH": ""],
            mlxDoctor: StaticMLXPackageDoctor.failure("not checked"),
            defaultSearchPaths: []
        ))

        let report = try service.validate(modelPath: modelURL.path, enginePreference: .auto)

        #expect(report.compatibleEngines == [.llamaCpp])
        #expect(report.readyEngine == nil)
        #expect(report.suggestedFixes.contains { $0.contains("brew install llama.cpp") })
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(named name: String) throws -> URL {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\necho version: fake\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
