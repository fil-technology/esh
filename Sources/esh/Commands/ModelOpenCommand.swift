import Foundation
import Darwin
import EshCore

enum ModelOpenCommand {
    static func run(
        identifier: String,
        service: ModelService,
        registry: RecommendedModelRegistry,
        catalogService: ModelCatalogService
    ) async throws {
        let url = try await resolveURL(
            identifier: identifier,
            service: service,
            registry: registry,
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
        registry: RecommendedModelRegistry,
        catalogService: ModelCatalogService
    ) async throws -> URL {
        if let recommended = registry.resolve(alias: identifier) {
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

        if isatty(STDIN_FILENO) == 0 || isatty(STDOUT_FILENO) == 0 {
            printChoices(results)
            throw StoreError.invalidManifest("Multiple matches found for \(identifier). Re-run with an exact repo id or alias.")
        }

        print("Choose a model page to open:")
        printChoices(results)
        print("Selection [1-\(results.count), 0 to cancel]: ", terminator: "")
        fflush(stdout)

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let index = Int(input) else {
            throw StoreError.invalidManifest("Open cancelled.")
        }
        if index == 0 {
            throw StoreError.invalidManifest("Open cancelled.")
        }
        guard results.indices.contains(index - 1) else {
            throw StoreError.invalidManifest("Invalid selection \(index).")
        }
        return results[index - 1]
    }

    private static func printChoices(_ results: [ModelSearchResult]) {
        print("no  model                              kind       date      downloads")
        for (offset, result) in results.enumerated() {
            let row = [
                pad("\(offset + 1).", width: 3),
                pad(result.displayName, width: 34),
                pad(result.backend?.rawValue ?? result.tags.first ?? "-", width: 10),
                pad(result.updatedAt.map(dateFormatter.string(from:)) ?? "-", width: 9),
                result.downloads.map(compactNumber(_:)) ?? "-"
            ].joined(separator: " ")
            print(row)
        }
    }

    private static func pad(_ value: String, width: Int) -> String {
        let truncated = truncate(value, limit: width)
        if truncated.count >= width {
            return truncated
        }
        return truncated + String(repeating: " ", count: width - truncated.count)
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        guard limit > 1 else { return String(value.prefix(limit)) }
        return String(value.prefix(limit - 1)) + "…"
    }

    private static func compactNumber(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}
