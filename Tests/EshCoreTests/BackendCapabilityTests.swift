import Foundation
import Testing
@testable import EshCore

@Suite
struct BackendCapabilityTests {
    @Test
    func mlxReportsStreamingAndPromptCacheCapabilitiesWhenInstallPathExists() {
        let installURL = temporaryDirectory()
        let install = modelInstall(id: "qwen-mlx", backend: .mlx, installURL: installURL, backendFormat: "mlx")

        let report = MLXBackend(runtimeVersion: "mlx-test").capabilityReport(for: install)

        #expect(report.backend == .mlx)
        #expect(report.runtimeVersion == "mlx-test")
        #expect(report.ready)
        #expect(report.supports(.directInference))
        #expect(report.supports(.tokenStreaming))
        #expect(report.supports(.promptCacheBuild))
        #expect(report.supports(.promptCacheLoad))
    }

    @Test
    func llamaCppReportsStreamingButMarksPromptCacheUnavailable() throws {
        let installURL = temporaryDirectory()
        try Data().write(to: installURL.appendingPathComponent("model.gguf"))
        let executableURL = try executable(named: "llama-cli")
        let install = modelInstall(id: "qwen-gguf", backend: .gguf, installURL: installURL, backendFormat: "gguf")
        let backend = LlamaCppBackend(
            runtimeVersion: "llama-test",
            executableResolver: { executableURL }
        )

        let report = backend.capabilityReport(for: install)

        #expect(report.backend == .gguf)
        #expect(report.runtimeVersion == "llama-test")
        #expect(report.ready)
        #expect(report.supports(.directInference))
        #expect(report.supports(.tokenStreaming))
        #expect(!report.supports(.promptCacheBuild))
        #expect(!report.supports(.promptCacheLoad))
        #expect(report.unavailableFeature(.promptCacheBuild)?.reason.contains("GGUF cache") == true)
    }

    @Test
    func llamaCppCapabilityReportKeepsErrorMessageWhenRuntimeIsMissing() throws {
        let installURL = temporaryDirectory()
        try Data().write(to: installURL.appendingPathComponent("model.gguf"))
        let install = modelInstall(id: "qwen-gguf", backend: .gguf, installURL: installURL, backendFormat: "gguf")
        let backend = LlamaCppBackend(
            runtimeVersion: "llama-test",
            executableResolver: {
                throw StoreError.invalidManifest("missing llama-cli")
            }
        )

        let report = backend.capabilityReport(for: install)

        #expect(!report.ready)
        #expect(report.warnings.contains { $0.contains("missing llama-cli") })
        #expect(!report.supports(.directInference))
        #expect(report.unavailableFeature(.directInference)?.reason.contains("missing llama-cli") == true)
    }

    private func modelInstall(
        id: String,
        backend: BackendKind,
        installURL: URL,
        backendFormat: String
    ) -> ModelInstall {
        ModelInstall(
            id: id,
            spec: ModelSpec(
                id: id,
                displayName: id,
                backend: backend,
                source: ModelSource(kind: .localPath, reference: installURL.path),
                tokenizerID: "tok-\(id)",
                architectureFingerprint: "arch-\(id)"
            ),
            installPath: installURL.path,
            sizeBytes: 42,
            backendFormat: backendFormat
        )
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
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
