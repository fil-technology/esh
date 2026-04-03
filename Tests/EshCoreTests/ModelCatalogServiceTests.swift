import Foundation
import Testing
@testable import EshCore

@Suite
struct ModelCatalogServiceTests {
    @Test
    func installedResultsAreRankedAheadOfRemoteMatches() async throws {
        let install = ModelInstall(
            id: "mlx-community--qwen2.5-0.5b-instruct-4bit",
            spec: ModelSpec(
                id: "mlx-community--qwen2.5-0.5b-instruct-4bit",
                displayName: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                backend: .mlx,
                source: ModelSource(kind: .huggingFace, reference: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
                localPath: "/tmp/model"
            ),
            installPath: "/tmp/model",
            sizeBytes: 1_024,
            backendFormat: "mlx"
        )

        let service = ModelCatalogService(
            localCatalog: StubCatalog(results: [
                ModelSearchResult(
                    id: install.id,
                    source: .local,
                    modelSource: install.spec.source,
                    displayName: install.spec.displayName,
                    backend: .mlx,
                    sizeBytes: install.sizeBytes,
                    isInstalled: true,
                    installedModelID: install.id,
                    installPath: install.installPath
                )
            ]),
            huggingFaceCatalog: StubCatalog(results: [
                ModelSearchResult(
                    id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                    source: .huggingFace,
                    modelSource: ModelSource(kind: .huggingFace, reference: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
                    displayName: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                    backend: .mlx,
                    downloads: 100
                )
            ]),
            modelStore: StubModelStore(installs: [install])
        )

        let results = try await service.search(query: "qwen", sourceFilter: .all, limit: 10)

        #expect(results.count == 1)
        #expect(results.first?.source == .local)
        #expect(results.first?.isInstalled == true)
        #expect(results.first?.installedModelID == install.id)
    }
}

private struct StubCatalog: ModelCatalog, Sendable {
    let results: [ModelSearchResult]

    func search(query: String, limit: Int) async throws -> [ModelSearchResult] {
        Array(results.prefix(limit))
    }
}

private struct StubModelStore: ModelStore, Sendable {
    let installs: [ModelInstall]

    func save(manifest: ModelManifest) throws {}
    func loadManifest(id: String) throws -> ModelManifest { throw StoreError.notFound("unused") }
    func listInstalls() throws -> [ModelInstall] { installs }
    func removeInstall(id: String) throws {}
    func prepareInstallDirectory(id: String) throws -> URL { URL(fileURLWithPath: "/tmp/\(id)") }
}
