import Foundation
import Testing
@testable import EshCore

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

@Test
func cacheManifestCarriesOptionalPromptCacheKey() throws {
    let key = PromptCacheKey(
        hash: "abc123",
        backend: .mlx,
        modelID: "demo",
        tokenizerID: "tok",
        runtimeVersion: "1.0",
        toolSignature: "tools:none",
        normalizedMessageCount: 2
    )
    let manifest = CacheManifest(
        backend: .mlx,
        modelID: "demo",
        tokenizerID: "tok",
        architectureFingerprint: "abc",
        runtimeVersion: "1.0",
        cacheFormatVersion: "v1",
        cacheMode: .raw,
        sessionID: UUID(),
        sessionName: "default",
        promptCacheKey: key
    )

    let data = try JSONCoding.encoder.encode(manifest)
    let decoded = try JSONCoding.decoder.decode(CacheManifest.self, from: data)

    #expect(decoded.promptCacheKey == key)
}

@Test
func cacheManifestDecodesWithoutPromptCacheKeyForBackwardCompatibility() throws {
    let json = """
    {
      "backend" : "mlx",
      "modelID" : "demo",
      "architectureFingerprint" : "abc",
      "runtimeVersion" : "1.0",
      "cacheFormatVersion" : "v1",
      "cacheMode" : "raw",
      "createdAt" : "2026-04-30T00:00:00Z",
      "sessionID" : "11111111-1111-1111-1111-111111111111",
      "sessionName" : "default"
    }
    """

    let decoded = try JSONCoding.decoder.decode(CacheManifest.self, from: Data(json.utf8))

    #expect(decoded.promptCacheKey == nil)
}
