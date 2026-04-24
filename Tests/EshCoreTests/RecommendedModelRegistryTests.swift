import Foundation
import Testing
@testable import EshCore

@Suite
struct RecommendedModelRegistryTests {
    @Test
    func preservesRequestedTierOrdering() {
        let registry = RecommendedModelRegistry()
        let ids = registry.list().map(\.id)

        #expect(ids.prefix(4).elementsEqual([
            "qwen-3-5-9b",
            "mistral-small-24b",
            "deepseek-r1-qwen-14b",
            "deepseek-r1-qwen-7b"
        ]))
        #expect(ids.suffix(3).elementsEqual([
            "qwen-3-5-27b-opus-distilled",
            "deepseek-r1-qwen-32b",
            "qwen-2-5-coder-32b"
        ]))
    }

    @Test
    func filtersByTierTagAndBackend() {
        let registry = RecommendedModelRegistry()

        let tierIDs = registry.list(tier: .tiny).map(\.id)
        let codingIDs = registry.list(tag: "coding").map(\.id)
        let backendIDs = registry.list(backend: .mlx).map(\.id)
        let ggufIDs = registry.list(backend: .gguf).map(\.id)

        #expect(tierIDs == ["qwen-2-5-0-5b", "qwen-3-5-0-8b-optiq", "qwen-3-5-0-8b", "gemma-4-e2b-it"])
        #expect(codingIDs == ["mistral-small-24b", "qwen-2-5-coder-7b", "qwen-2-5-coder-7b-gguf", "qwen-2-5-coder-32b"])
        #expect(backendIDs.count == 19)
        #expect(ggufIDs == [
            "qwen-3-5-9b-gguf",
            "deepseek-r1-qwen-14b-gguf",
            "llama-3-2-3b-gguf",
            "qwen-2-5-coder-7b-gguf",
            "deepseek-r1-qwen-7b-gguf",
            "phi-4-mini-reasoning-gguf",
            "phi-3-5-mini-instruct-gguf"
        ])
    }

    @Test
    func resolvesAliasRepoAndRecommendedPrefix() {
        let registry = RecommendedModelRegistry()

        #expect(registry.resolve(alias: "qwen-2-5-0-5b")?.repoID == "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        #expect(registry.resolve(alias: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit")?.id == "qwen-2-5-coder-32b")
        #expect(registry.resolve(alias: "recommended:qwen-2-5-coder-7b")?.repoID == "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        #expect(registry.resolve(alias: "qwen-3-5-9b")?.repoID == "mlx-community/Qwen3.5-9B-MLX-4bit")
        #expect(registry.resolve(alias: "bartowski/Qwen_Qwen3.5-9B-GGUF")?.id == "qwen-3-5-9b-gguf")
    }
}

@Suite
struct ModelServiceRecommendedCatalogTests {
    @Test
    func exposesRecommendedCatalogThroughServiceLayer() {
        let service = ModelService(
            store: TestModelStore(),
            downloader: TestModelDownloader()
        )

        let models = service.listRecommended(tier: .small, tag: "coding")
        let ggufModels = service.listRecommended(backend: .gguf)

        #expect(models.map(\.id) == ["qwen-2-5-coder-7b", "qwen-2-5-coder-7b-gguf"])
        #expect(ggufModels.map(\.id) == [
            "qwen-3-5-9b-gguf",
            "deepseek-r1-qwen-14b-gguf",
            "llama-3-2-3b-gguf",
            "qwen-2-5-coder-7b-gguf",
            "deepseek-r1-qwen-7b-gguf",
            "phi-4-mini-reasoning-gguf",
            "phi-3-5-mini-instruct-gguf"
        ])
        #expect(service.resolveRecommended(alias: "qwen-2-5-0-5b")?.title == "Qwen 2.5 0.5B Instruct")
        #expect(service.resolveRecommended(alias: "qwen-3-5-9b")?.title == "Qwen 3.5 9B")
    }
}

private struct TestModelDownloader: ModelDownloader {
    func install(
        source: ModelSource,
        suggestedID: String?,
        variant: String?,
        progress: @escaping @Sendable (DownloadState) -> Void
    ) async throws -> ModelManifest {
        throw StoreError.invalidManifest("Not used in this test.")
    }
}

private struct TestModelStore: ModelStore {
    func save(manifest: ModelManifest) throws {}

    func loadManifest(id: String) throws -> ModelManifest {
        throw StoreError.notFound(id)
    }

    func listInstalls() throws -> [ModelInstall] {
        []
    }

    func removeInstall(id: String) throws {}

    func prepareInstallDirectory(id: String) throws -> URL {
        URL(fileURLWithPath: "/tmp/\(id)")
    }
}
