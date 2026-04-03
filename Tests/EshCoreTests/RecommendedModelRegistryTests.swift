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
            "gemma-4-26b-a4b",
            "mistral-small-24b",
            "deepseek-r1-qwen-14b",
            "qwen-3-5-9b-optiq"
        ]))
        #expect(ids.suffix(5).elementsEqual([
            "gemma-4-31b",
            "qwen-3-5-35b-a3b",
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

        #expect(tierIDs == ["gemma-4-e2b", "qwen-3-5-0-8b-optiq"])
        #expect(codingIDs == ["mistral-small-24b", "qwen-2-5-coder-7b", "qwen-3-5-35b-a3b", "qwen-2-5-coder-32b"])
        #expect(backendIDs.count == RecommendedModelRegistry.defaultModels.count)
    }

    @Test
    func resolvesAliasRepoAndRecommendedPrefix() {
        let registry = RecommendedModelRegistry()

        #expect(registry.resolve(alias: "gemma-4-26b-a4b")?.repoID == "mlx-community/gemma-4-26b-a4b-it-4bit")
        #expect(registry.resolve(alias: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit")?.id == "qwen-2-5-coder-32b")
        #expect(registry.resolve(alias: "recommended:qwen-2-5-coder-7b")?.repoID == "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
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

        #expect(models.map(\.id) == ["qwen-2-5-coder-7b"])
        #expect(service.resolveRecommended(alias: "qwen-3-5-35b-a3b")?.title == "Qwen 3.5 35B A3B Instruct")
    }
}

private struct TestModelDownloader: ModelDownloader {
    func install(
        source: ModelSource,
        suggestedID: String?,
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
