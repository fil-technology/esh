import Foundation
import Testing
@testable import LLMCacheCore

@Test
func cacheManifestCapturesModeAndVersioning() {
    let manifest = CacheManifest(
        backend: .mlx,
        modelID: "demo",
        tokenizerID: "tok",
        architectureFingerprint: "abc",
        runtimeVersion: "1.0",
        cacheFormatVersion: "v1",
        compressorVersion: "turboquant-1",
        cacheMode: .turbo,
        sessionID: UUID(),
        sessionName: "default"
    )

    #expect(manifest.cacheMode == .turbo)
    #expect(manifest.compressorVersion == "turboquant-1")
}
