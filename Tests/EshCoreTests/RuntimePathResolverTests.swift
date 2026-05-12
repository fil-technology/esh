import Foundation
import Testing
@testable import EshCore

@Suite
struct RuntimePathResolverTests {
    @Test
    func packagedExecutablePrefersPackagedHelperScript() throws {
        let root = temporaryDirectory()
        let executable = root.appendingPathComponent("bin/esh")
        let helper = root.appendingPathComponent("share/esh/Tools/mlx_vlm_bridge.py")

        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try Data().write(to: helper)

        let resolved = try RuntimePathResolver.helperScriptURL(
            configuredPath: nil,
            environment: [:],
            executablePath: executable.path,
            sourceFilePath: "/Users/runner/work/esh/esh/Sources/EshCore/Backends/MLX/MLXBridge.swift"
        )

        #expect(resolved == helper)
    }

    @Test
    func packagedExecutablePrefersBundledPython() throws {
        let root = temporaryDirectory()
        let executable = root.appendingPathComponent("bin/esh")
        let python = root.appendingPathComponent("python/bin/python3")

        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let resolved = RuntimePathResolver.pythonExecutableURL(
            configuredPath: nil,
            environment: [:],
            executablePath: executable.path,
            sourceFilePath: "/Users/runner/work/esh/esh/Sources/EshCore/Backends/MLX/MLXBridge.swift"
        )

        #expect(resolved == python)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
