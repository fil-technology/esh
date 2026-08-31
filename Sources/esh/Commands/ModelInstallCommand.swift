import Foundation
import Darwin
import EshCore

enum ModelInstallCommand {
    static func run(
        identifier: String,
        variant: String? = nil,
        forceUnsupportedRuntime: Bool = false,
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

        // Hard pre-download fit gate: estimate whether this model fits and runs on this Mac BEFORE
        // downloading multi-GB weights. Soft gates (tight/unlikely/unknown) require confirmation
        // but never silently block or substitute; only genuine incompatibility blocks.
        let fit = await assessFit(resolved: resolved ?? service.resolveRecommended(alias: repoID), repoID: repoID)
        if !handleFit(fit, repoID: repoID, force: forceUnsupportedRuntime) {
            throw CLIHandledError()
        }

        let preflight = try await ModelInstallPreflightService().evaluate(
            repoID: repoID,
            recommendedModel: resolved ?? service.resolveRecommended(alias: repoID),
            searchResult: selectedSearchResult,
            variant: resolvedVariant,
            forceUnsupportedRuntime: forceUnsupportedRuntime
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

    static func assessFit(resolved: RecommendedModel?, repoID: String) async -> ModelFitAssessment {
        let host = HostMachineProfileService().currentProfile()
        let root = PersistenceRoot.default()
        if let resolved {
            return ModelFitService().assess(recommendedModel: resolved, contextTokens: nil, host: host, root: root)
        }
        if let metadata = try? await ModelMetadataInspector().inspect(repoID: repoID, backendPreference: .auto, offline: false) {
            let input = ModelFitService.Input(
                parameterCountB: metadata.parameterCountB,
                effectiveBits: metadata.effectiveBits,
                format: metadata.format,
                backend: metadata.backend,
                contextTokens: 8192,
                diskRequiredBytes: metadata.estimatedWeightsGB.map { Int64($0 * 1.1 * 1_073_741_824) }
            )
            return ModelFitService().assess(input: input, host: host, root: root)
        }
        return ModelFitAssessment(fitClass: .unknown, reasons: ["Could not fetch model metadata before download."])
    }

    static func renderFit(_ fit: ModelFitAssessment, label: String) {
        print("Model fit for this Mac — \(label): \(fit.fitClass.headline)")
        if let peak = fit.estimatedPeakMemoryGB, let usable = fit.usableMemoryGB {
            print(String(format: "  memory: ~%.1f GB peak vs ~%.1f GB usable", peak, usable))
        }
        if let req = fit.diskRequiredGB, let free = fit.diskFreeGB {
            print(String(format: "  disk: ~%.1f GB needed, ~%.1f GB free%@", req, free, fit.diskSufficient ? "" : "  ⚠ insufficient"))
        }
        for reason in fit.reasons { print("  - \(reason)") }
        if let opt = fit.expectedOptimization { print("  suggestion: \(opt)") }
        if let ctx = fit.recommendedContext { print("  recommended context: \(ctx) tokens") }
    }

    private static func handleFit(_ fit: ModelFitAssessment, repoID: String, force: Bool) -> Bool {
        renderFit(fit, label: repoID)
        if fit.isBlocked {
            print("Cannot install \(repoID): \(fit.blockers.isEmpty ? (fit.storageAvailable ? "unsupported" : "storage volume unavailable") : fit.blockers.joined(separator: "; ")).")
            return false
        }
        guard fit.requiresConfirmation, !force else { return true }

        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        if !interactive {
            print("Fit is '\(fit.fitClass.rawValue)' on this Mac. Re-run with --force to install anyway (esh will not substitute a different model).")
            return false
        }
        let prompt = InteractiveChoicePrompt()
        let strong = fit.fitClass == .unlikely
        let choice = prompt.choose(
            title: strong ? "This Model May Not Run Well" : "Confirm Install",
            message: "\(repoID) is '\(fit.fitClass.rawValue)' on this Mac. \(strong ? "It may swap heavily or fail to load." : "Proceed?")",
            details: fit.reasons + (fit.expectedOptimization.map { [$0] } ?? []),
            choices: [.init(key: "y", label: strong ? "Install anyway" : "Install"), .init(key: "n", label: "Cancel")],
            footer: "←/→ navigate • enter confirm • esc cancel"
        )
        return choice == "y"
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
