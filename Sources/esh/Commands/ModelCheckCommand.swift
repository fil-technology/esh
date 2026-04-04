import Foundation
import Darwin
import EshCore

enum ModelCheckCommand {
    static func run(
        arguments: [String],
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws {
        let jsonOutput = arguments.contains("--json")
        let strict = arguments.contains("--strict")
        let offline = arguments.contains("--offline")
        let variant = CommandSupport.optionalValue(flag: "--variant", in: arguments)
        let backendPreference = try resolveBackendPreference(
            CommandSupport.optionalValue(flag: "--backend", in: arguments) ?? "auto"
        )
        let contextTokens = Int(CommandSupport.optionalValue(flag: "--context", in: arguments) ?? "4096") ?? 4096
        let positional = CommandSupport.positionalArguments(
            in: arguments,
            knownFlags: ["--backend", "--context", "--variant"]
        ).filter { !$0.hasPrefix("--") }

        guard let identifier = positional.first else {
            throw StoreError.invalidManifest(
                "Usage: esh model check <model-or-repo> [--backend mlx|gguf|auto] [--context N] [--variant <name>] [--json] [--strict] [--offline]"
            )
        }

        let repoID = try await resolveRepoID(identifier: identifier, service: service, catalogService: catalogService)
        let result = try await ModelCheckService().evaluate(
            repoID: repoID,
            backendPreference: backendPreference,
            contextTokens: contextTokens,
            strict: strict,
            offline: offline,
            variant: variant
        )

        if jsonOutput {
            let data = try JSONCoding.encoder.encode(result)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        print("Model: \(result.model)")
        print("Backend: \(result.backendLabel)")
        print("Format: \(result.format.rawValue.uppercased())")
        print("Architecture: \(result.architecture.rawValue)")
        print("Parameters: \(formattedParameters(result.parameterCountB))")
        print("Quantization: \(result.quantization ?? "unknown")")
        if let selectedVariant = result.selectedVariant {
            print("Variant: \(selectedVariant)")
        } else if !result.availableVariants.isEmpty {
            print("Variants: \(result.availableVariants.joined(separator: ", "))")
        }
        print("")
        print("Weights estimate: \(formattedGB(result.estimatedWeightsGB))")
        print("Runtime estimate: \(formattedGB(result.estimatedRuntimeGB))")
        print("Safe local budget: \(formattedGB(result.safeLocalBudgetGB))")
        print("")
        print("Verdict: \(result.verdict.rawValue)")
        if !result.notes.isEmpty {
            print("")
            print("Notes:")
            for note in result.notes {
                print("- \(note)")
            }
        }
        if !result.warnings.isEmpty {
            print("")
            print("Warnings:")
            for warning in result.warnings {
                print("- \(warning)")
            }
        }
    }

    private static func resolveRepoID(
        identifier: String,
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws -> String {
        if let recommended = service.resolveRecommended(alias: identifier) {
            return recommended.repoID
        }

        if identifier.contains("/") {
            return identifier
        }

        if let install = try? service.list().first(where: {
            $0.id.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.spec.source.reference.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.spec.displayName.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return install.spec.source.reference
        }

        let results = try await catalogService.search(query: identifier, sourceFilter: .hf, limit: 8)
        guard !results.isEmpty else {
            throw StoreError.notFound("No remote models found for \(identifier).")
        }

        if results.count == 1 || isatty(STDIN_FILENO) == 0 || isatty(STDOUT_FILENO) == 0 {
            return results[0].modelSource.reference
        }
        let selected = try ModelSearchPicker.pick(
            title: "Choose A Model To Check",
            subtitle: "Use ↑/↓ and Enter to choose the model to inspect before download. Esc cancels.",
            results: results
        )
        return selected.modelSource.reference
    }

    private static func resolveBackendPreference(_ value: String) throws -> ModelCheckBackendPreference {
        guard let preference = ModelCheckBackendPreference(rawValue: value.lowercased()) else {
            throw StoreError.invalidManifest("Unknown backend \(value). Use auto, mlx, or gguf.")
        }
        return preference
    }

    private static func formattedParameters(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        if value.rounded() == value {
            return "\(Int(value))B"
        }
        return String(format: "%.1fB", value)
    }

    private static func formattedGB(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.1f GB", value)
    }
}
