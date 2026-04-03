import Foundation
import EshCore

enum ModelRecommendedCommand {
    static func run(arguments: [String], registry: RecommendedModelRegistry) throws {
        let profileValue = CommandSupport.optionalValue(flag: "--profile", in: arguments)
        let profile = try profileValue.map(resolveProfile)
        let models = registry.list(profile: profile)
        guard !models.isEmpty else {
            print("No recommended models found.")
            return
        }

        print("alias          profile  tier      memory   size     repo")
        for model in models {
            print(
                [
                    pad(model.id, width: 14),
                    pad(model.profile.rawValue, width: 8),
                    pad(model.tier.rawValue, width: 9),
                    pad(model.memoryHint, width: 8),
                    pad(model.sizeHint, width: 8),
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

    private static func pad(_ value: String, width: Int) -> String {
        if value.count >= width { return String(value.prefix(width)) }
        return value + String(repeating: " ", count: width - value.count)
    }
}
