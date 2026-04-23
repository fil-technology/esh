import Foundation
import Darwin
import EshCore

enum ModelInstallCommand {
    static func run(
        identifier: String,
        variant: String? = nil,
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws {
        let resolved = service.resolveRecommended(alias: identifier)
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

        let resolvedVariant = try await resolveVariantIfNeeded(
            repoID: repoID,
            requestedVariant: variant,
            interactive: isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        )

        let preflight = try await ModelInstallPreflightService().evaluate(
            repoID: repoID,
            recommendedModel: resolved ?? service.resolveRecommended(alias: repoID),
            searchResult: selectedSearchResult,
            variant: resolvedVariant
        )
        if !handlePreflight(preflight, repoID: repoID) {
            throw CLIHandledError()
        }

        let manifest = try await service.install(repoID: repoID, variant: resolvedVariant) { state in
            DownloadProgressView.render(state: state)
        }
        if let resolved {
            print(installedMessage(alias: resolved.id, manifest: manifest))
        } else {
            print(installedMessage(alias: nil, manifest: manifest))
        }
    }

    private static func installedMessage(alias: String?, manifest: ModelManifest) -> String {
        let variantSuffix = manifest.install.spec.variant.map { " [variant \($0)]" } ?? ""
        if let alias {
            return "Installed \(alias) (\(manifest.install.id))\(variantSuffix) at \(manifest.install.installPath)"
        }
        return "Installed \(manifest.install.id)\(variantSuffix) at \(manifest.install.installPath)"
    }

    private static func resolveVariantIfNeeded(
        repoID: String,
        requestedVariant: String?,
        interactive: Bool
    ) async throws -> String? {
        if let requestedVariant, !requestedVariant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return requestedVariant.uppercased()
        }

        let metadata = try? await ModelMetadataInspector().inspect(
            repoID: repoID,
            backendPreference: .auto,
            offline: false
        )
        guard let metadata,
              metadata.format == .gguf,
              metadata.availableVariants.count > 1 else {
            return requestedVariant
        }

        if interactive {
            return try await GGUFVariantPicker.pick(
                repoID: repoID,
                metadata: metadata
            )
        }

        throw StoreError.invalidManifest(
            "Multiple GGUF variants are available for \(repoID): \(metadata.availableVariants.joined(separator: ", ")). Re-run with --variant <name>."
        )
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
            title: "Choose A Model To Install",
            subtitle: "Use ↑/↓ and Enter to choose the repo to install. Esc cancels.",
            results: results
        )
    }

    private static func handlePreflight(_ report: ModelInstallPreflightReport, repoID: String) -> Bool {
        guard !report.notes.isEmpty || !report.warnings.isEmpty || !report.blockers.isEmpty else {
            return true
        }

        let detailLines = report.notes
            + report.warnings.map { "Warning: \($0)" }
            + report.blockers.map { "Blocked: \($0.replacingOccurrences(of: "\n", with: " "))" }

        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        if interactive {
            let prompt = InteractiveChoicePrompt()
            if report.isBlocked {
                _ = prompt.choose(
                    title: "Model Cannot Run Here",
                    message: "\(repoID) is not currently installable with this machine/runtime setup.",
                    details: detailLines,
                    choices: [.init(key: "n", label: "Back")],
                    footer: "enter confirm • < back • esc cancel"
                )
                return false
            }
        }

        let nonBlockingLines = report.notes + report.warnings.map { "Warning: \($0)" }
        if !nonBlockingLines.isEmpty {
            print("Installing \(repoID)")
            for line in nonBlockingLines {
                print("  - \(line)")
            }
        }
        return !report.isBlocked
    }
}
