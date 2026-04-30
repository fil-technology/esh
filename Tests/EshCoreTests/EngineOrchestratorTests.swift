import Foundation
import Testing
@testable import EshCore

@Suite
struct EngineOrchestratorTests {
    @Test
    func llamaCppDetectionUsesEnvironmentWithoutInstallingAnything() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let fakeLlama = try executable(named: "llama-cli", output: "version: fake")
        let service = EngineOrchestratorService(
            root: root,
            environment: [
                "ESH_LLAMA_CPP_CLI": fakeLlama.path,
                "PATH": ""
            ],
            mlxDoctor: StaticMLXPackageDoctor.failure("not checked"),
            defaultSearchPaths: []
        )

        let status = try service.status(for: .llamaCpp)

        #expect(status.id == .llamaCpp)
        #expect(status.required)
        #expect(status.enabled)
        #expect(status.installed)
        #expect(status.ready)
        #expect(status.executablePath == fakeLlama.path)
        #expect(status.notes.contains { $0.contains("passive") })
        #expect(LlamaCppBackend.runtimeNotFoundMessage.contains("brew install llama.cpp"))
        #expect(LlamaCppBackend.runtimeNotFoundMessage.contains("automatic bootstrap") == false)
    }

    @Test
    func optionalEnginesAreTrackedButDisabledByDefault() throws {
        let service = EngineOrchestratorService(
            root: PersistenceRoot(rootURL: temporaryDirectory()),
            environment: ["PATH": ""],
            mlxDoctor: StaticMLXPackageDoctor.failure("not checked"),
            defaultSearchPaths: []
        )

        let statuses = try service.listEngines(config: .default)

        let llamafile = try #require(statuses.first(where: { $0.id == .llamafile }))
        #expect(llamafile.required == false)
        #expect(llamafile.enabled == false)
        #expect(llamafile.ready == false)

        let ollama = try #require(statuses.first(where: { $0.id == .ollama }))
        #expect(ollama.required == false)
        #expect(ollama.enabled == false)
        #expect(ollama.ready == false)
    }

    @Test
    func mlxDoctorReportsPackageFailureAsMissingDependency() throws {
        let service = EngineOrchestratorService(
            root: PersistenceRoot(rootURL: temporaryDirectory()),
            environment: ["PATH": ""],
            mlxDoctor: StaticMLXPackageDoctor.failure("No module named mlx_lm"),
            defaultSearchPaths: []
        )

        let status = try service.status(for: .mlx)

        #expect(status.id == .mlx)
        #expect(status.required)
        #expect(status.installed == false)
        #expect(status.ready == false)
        #expect(status.warnings.contains { $0.contains("No module named mlx_lm") })
        #expect(status.suggestedFix?.contains("python -m pip install") == true)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(named name: String, output: String) throws -> URL {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent(name)
        let script = "#!/bin/sh\necho '\(output)'\n"
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

struct StaticMLXPackageDoctor: MLXPackageDoctor {
    enum Result {
        case success(MLXPackageDoctorReport)
        case failure(String)
    }

    let result: Result

    static func success() -> StaticMLXPackageDoctor {
        StaticMLXPackageDoctor(result: .success(MLXPackageDoctorReport(
            pythonExecutable: "/tmp/python",
            mlxVersion: "0.26.0",
            mlxLMVersion: "0.25.0",
            mlxVLMVersion: "0.4.3",
            numpyVersion: "2.0.0",
            safetensorsVersion: "0.5.0"
        )))
    }

    static func failure(_ message: String) -> StaticMLXPackageDoctor {
        StaticMLXPackageDoctor(result: .failure(message))
    }

    func check() throws -> MLXPackageDoctorReport {
        switch result {
        case .success(let report):
            return report
        case .failure(let message):
            throw StoreError.invalidManifest(message)
        }
    }
}
