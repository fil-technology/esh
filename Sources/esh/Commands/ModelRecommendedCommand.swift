import Foundation
import EshCore

enum ModelRecommendedCommand {
    static func run(arguments: [String], service: ModelService) throws {
        let profileValue = CommandSupport.optionalValue(flag: "--profile", in: arguments)
        let tierValue = CommandSupport.optionalValue(flag: "--tier", in: arguments)
        let backendValue = CommandSupport.optionalValue(flag: "--backend", in: arguments)
        let tag = CommandSupport.optionalValue(flag: "--tag", in: arguments)
        let forThisMac = arguments.contains("--for-this-mac")
        let includeExperimental = arguments.contains("--experimental")
        let backend = try backendValue.map(resolveBackend)

        // Hardware-aware mode: `--for-this-mac`, or a use-case profile like coding/reasoning/fast.
        if forThisMac || (profileValue.flatMap(RecommendedModelRegistry.UseCase.init(cliValue:)).map(isUseCaseOnly) ?? false) {
            let useCase = profileValue.flatMap(RecommendedModelRegistry.UseCase.init(cliValue:)) ?? .bestForThisMac
            let host = HostMachineProfileService().currentProfile()
            let models = service.recommend(
                useCase: useCase,
                host: forThisMac ? host : nil,
                backend: backend,
                limit: forThisMac ? 4 : 8,
                includeExperimental: includeExperimental
            )
            if let budget = host.safeBudgetGB, forThisMac {
                print("For this Mac (\(host.chipDescription ?? "Apple Silicon"), ~\(String(format: "%.0f", budget)) GB usable) — \(useCase.title):")
            } else {
                print("\(useCase.title):")
            }
            printTable(models)
            return
        }

        let profile = try profileValue.map(resolveProfile)
        let tier = try tierValue.map(resolveTier)
        let models = service.listRecommended(profile: profile, tier: tier, backend: backend, tag: tag)
        printTable(models)
    }

    /// Whether a --profile value is a hardware-aware use case that is NOT one of the legacy
    /// chat/code profiles (so `--profile chat` keeps the classic listing).
    private static func isUseCaseOnly(_ useCase: RecommendedModelRegistry.UseCase) -> Bool {
        switch useCase {
        case .general, .coding: return false   // overlap with legacy chat/code profiles
        case .reasoning, .fast, .lowMemory, .bestForThisMac: return true
        }
    }

    private static func printTable(_ models: [RecommendedModel]) {
        guard !models.isEmpty else {
            print("No recommended models found.")
            return
        }
        print("alias                        tier    quant  ctx   memory    disk      status        capabilities                 repo")
        for model in models {
            print(
                [
                    pad(model.id, width: 28),
                    pad(tierLabel(for: model.tier), width: 7),
                    pad(model.quantization, width: 6),
                    pad(model.contextHint, width: 5),
                    pad(model.memoryHint, width: 9),
                    pad(model.sizeHint, width: 9),
                    pad(model.status.rawValue, width: 13),
                    pad(model.capabilities.map(\.rawValue).joined(separator: ","), width: 28),
                    model.repoID
                ].joined(separator: " ")
            )
        }
    }

    private static func resolveProfile(_ value: String) throws -> RecommendedModel.Profile {
        guard let profile = RecommendedModel.Profile(rawValue: value.lowercased()) else {
            throw StoreError.invalidManifest("Unknown profile \(value). Use chat or code.")
        }
        return profile
    }

    private static func resolveTier(_ value: String) throws -> RecommendedModel.Tier {
        switch value.lowercased() {
        case "good":
            return .good
        case "small":
            return .small
        case "tiny":
            return .tiny
        case "max":
            return .max
        default:
            throw StoreError.invalidManifest("Unknown tier \(value). Use good, small, tiny, or max.")
        }
    }

    private static func resolveBackend(_ value: String) throws -> BackendKind {
        guard let backend = BackendKind(rawValue: value.lowercased()) else {
            throw StoreError.invalidManifest("Unknown backend \(value). Use mlx, gguf, or onnx.")
        }
        return backend
    }

    private static func tierLabel(for tier: RecommendedModel.Tier) -> String {
        switch tier {
        case .good:
            return "good"
        case .small:
            return "small"
        case .tiny:
            return "tiny"
        case .max:
            return "max"
        }
    }

    private static func pad(_ value: String, width: Int) -> String {
        let truncated = truncate(value, limit: width)
        if truncated.count >= width { return truncated }
        return truncated + String(repeating: " ", count: width - truncated.count)
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        guard limit > 1 else { return String(value.prefix(limit)) }
        return String(value.prefix(limit - 1)) + "…"
    }
}
