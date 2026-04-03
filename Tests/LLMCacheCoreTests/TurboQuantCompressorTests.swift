import Foundation
import Testing
@testable import LLMCacheCore

@Suite
struct TurboQuantCompressorTests {
    @Test
    func bridgeUsesHelperProcessForRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("turboquant-mock.sh")
        let script = """
        #!/bin/sh
        script="$1"
        mode="$2"
        if [ "$mode" = "turboquant-compress" ]; then
          cat
        else
          cat
        fi
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let compressor = TurboQuantCompressor(
            bridge: TurboQuantBridge(configuration: .init(
                pythonExecutablePath: scriptURL.path,
                helperScriptPath: "/tmp/ignored.py"
            ))
        )
        let input = Data("hello".utf8)

        let compressed = try await compressor.compress(input)
        let decompressed = try await compressor.decompress(compressed.data)

        #expect(compressed.originalSize == 5)
        #expect(decompressed == input)
    }
}
