import Foundation
import Darwin
import EshCore

enum ModelInstallCommand {
    static func run(
        identifier: String,
        service: ModelService,
        registry: RecommendedModelRegistry,
        catalogService: ModelCatalogService
    ) async throws {
        let resolved = registry.resolve(alias: identifier)
        let repoID: String
        let resolutionMessage: String?
        let selectedSearchResult: ModelSearchResult?

        if let resolved {
            repoID = resolved.repoID
            resolutionMessage = "Resolved alias \(identifier) -> \(repoID)"
            selectedSearchResult = nil
        } else if identifier.contains("/") {
            repoID = identifier
            resolutionMessage = nil
            selectedSearchResult = nil
        } else {
            let choice = try await resolveInteractiveSearchTerm(for: identifier, service: catalogService)
            repoID = choice.modelSource.reference
            resolutionMessage = "Selected \(repoID)"
            selectedSearchResult = choice
        }

        if let resolutionMessage {
            print(resolutionMessage)
        }

        try runResourcePreflight(
            repoID: repoID,
            recommendedModel: resolved ?? registry.resolve(alias: repoID),
            searchResult: selectedSearchResult
        )

        let manifest = try await service.install(repoID: repoID) { state in
            DownloadProgressView.render(state: state)
        }
        if let resolved {
            print("Installed \(resolved.id) (\(manifest.install.id)) at \(manifest.install.installPath)")
        } else {
            print("Installed \(manifest.install.id) at \(manifest.install.installPath)")
        }
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
            throw StoreError.invalidManifest("Multiple matches found for \(identifier). Re-run with an exact repo id or a recommended alias.")
        }

        print("Choose a model to install:")
        printChoices(results)
        print("Selection [1-\(results.count), 0 to cancel]: ", terminator: "")
        fflush(stdout)

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let index = Int(input) else {
            throw StoreError.invalidManifest("Install cancelled.")
        }
        if index == 0 {
            throw StoreError.invalidManifest("Install cancelled.")
        }
        guard results.indices.contains(index - 1) else {
            throw StoreError.invalidManifest("Invalid selection \(index).")
        }
        return results[index - 1]
    }

    private static func runResourcePreflight(
        repoID: String,
        recommendedModel: RecommendedModel?,
        searchResult: ModelSearchResult?
    ) throws {
        if let requirement = ModelMemoryAdvisor.requiredMemoryBytes(
            recommendedModel: recommendedModel,
            searchResult: searchResult
        ), let memory = SystemMemory.snapshot() {
            if memory.totalBytes < requirement {
                throw StoreError.invalidManifest(
                    """
                    Not enough unified memory for \(repoID).
                    Recommended: \(ByteFormatting.string(for: requirement))
                    This Mac: \(ByteFormatting.string(for: memory.totalBytes)) total
                    Choose a smaller model.
                    """
                )
            }

            if memory.availableBytes < requirement {
                throw StoreError.invalidManifest(
                    """
                    Not enough available memory to start downloading \(repoID).
                    Recommended free memory: \(ByteFormatting.string(for: requirement))
                    Available now: \(ByteFormatting.string(for: memory.availableBytes))
                    Close other apps or choose a smaller model.
                    """
                )
            }
        }

        if let diskRequirement = ModelMemoryAdvisor.requiredDiskBytes(
            recommendedModel: recommendedModel,
            searchResult: searchResult
        ), let storage = SystemStorage.snapshot(at: PersistenceRoot.default().modelsURL) {
            if storage.availableBytes < diskRequirement {
                throw StoreError.invalidManifest(
                    """
                    Not enough disk space to download \(repoID).
                    Required free space: \(ByteFormatting.string(for: diskRequirement))
                    Available now: \(ByteFormatting.string(for: storage.availableBytes))
                    Free space or choose a smaller model.
                    """
                )
            }
        } else if let diskRequirement = ModelMemoryAdvisor.requiredDiskBytes(
            recommendedModel: recommendedModel,
            searchResult: searchResult
        ) {
            print(
                """
                Note: could not verify free disk space automatically for \(repoID).
                Estimated required free space: \(ByteFormatting.string(for: diskRequirement))
                """
            )
        }
    }

    private static func printChoices(_ results: [ModelSearchResult]) {
        print("no  model                              kind       date      downloads")
        for (offset, result) in results.enumerated() {
            let row = [
                pad("\(offset + 1).", width: 3),
                pad(result.displayName, width: 34),
                pad(result.tags.first ?? result.backend?.rawValue ?? "-", width: 10),
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
