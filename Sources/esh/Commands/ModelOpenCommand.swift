import Foundation
import Darwin
import EshCore

enum ModelOpenCommand {
    static func run(
        identifier: String,
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws {
        let url = try await resolveURL(
            identifier: identifier,
            service: service,
            catalogService: catalogService
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw StoreError.invalidManifest("Failed to open \(url.absoluteString)")
        }

        print("Opened \(url.absoluteString)")
    }

    static func resolveURL(
        identifier: String,
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws -> URL {
        if let recommended = service.resolveRecommended(alias: identifier) {
            return try url(forRepoID: recommended.repoID)
        }

        if identifier.contains("/") {
            return try url(forRepoID: identifier)
        }

        if let install = try? service.list().first(where: {
            $0.id.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.spec.source.reference.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.spec.displayName.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return try url(forInstall: install)
        }

        let selected = try await resolveInteractiveSearchTerm(for: identifier, service: catalogService)
        return try url(forSearchResult: selected)
    }

    private static func url(forInstall install: ModelInstall) throws -> URL {
        switch install.spec.source.kind {
        case .huggingFace:
            return try url(forRepoID: install.spec.source.reference)
        case .localPath:
            throw StoreError.invalidManifest("Local-path models do not have a remote URL to open.")
        }
    }

    private static func url(forSearchResult result: ModelSearchResult) throws -> URL {
        switch result.modelSource.kind {
        case .huggingFace:
            return try url(forRepoID: result.modelSource.reference)
        case .localPath:
            throw StoreError.invalidManifest("Local-path models do not have a remote URL to open.")
        }
    }

    private static func url(forRepoID repoID: String) throws -> URL {
        guard let url = URL(string: "https://huggingface.co/\(repoID)") else {
            throw StoreError.invalidManifest("Invalid model repo id: \(repoID)")
        }
        return url
    }

    private static func resolveInteractiveSearchTerm(
        for identifier: String,
        service: ModelCatalogService
    ) async throws -> ModelSearchResult {
        let results = try await service.search(query: identifier, sourceFilter: .hf, limit: 8)
        guard !results.isEmpty else {
            throw StoreError.notFound("No remote models found for \(identifier).")
        }
        return try ModelSearchPicker.pick(
            title: "Choose A Model Page To Open",
            subtitle: "Use ↑/↓ and Enter to choose the model page. Esc cancels.",
            results: results
        )
    }
}
