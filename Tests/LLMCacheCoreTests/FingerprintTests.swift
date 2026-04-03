import Testing
@testable import LLMCacheCore

@Test
func fingerprintIsStableForSameInputs() {
    let first = Fingerprint.sha256(["mlx", "qwen", "runtime"])
    let second = Fingerprint.sha256(["mlx", "qwen", "runtime"])

    #expect(first == second)
}
