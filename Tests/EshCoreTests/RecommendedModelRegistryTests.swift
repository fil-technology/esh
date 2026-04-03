import Testing
@testable import EshCore

@Suite
struct RecommendedModelRegistryTests {
    @Test
    func resolvesAliasAndRecommendedPrefix() {
        let registry = RecommendedModelRegistry()

        #expect(registry.resolve(alias: "fast-chat")?.repoID == "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        #expect(registry.resolve(alias: "recommended:quality-code")?.repoID == "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
    }
}
