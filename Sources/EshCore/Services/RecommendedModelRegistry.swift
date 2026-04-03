import Foundation

public struct RecommendedModelRegistry: Sendable {
    private let models: [RecommendedModel]

    public init(models: [RecommendedModel] = RecommendedModelRegistry.defaultModels) {
        self.models = models
    }

    public func list(profile: RecommendedModel.Profile? = nil) -> [RecommendedModel] {
        let filtered = models.filter { model in
            guard let profile else { return true }
            return model.profile == profile
        }
        return filtered.sorted { lhs, rhs in
            if lhs.profile != rhs.profile {
                return lhs.profile.rawValue < rhs.profile.rawValue
            }
            return rank(lhs.tier) < rank(rhs.tier)
        }
    }

    public func resolve(alias: String) -> RecommendedModel? {
        let normalized = alias.lowercased()
        return models.first { model in
            model.id.lowercased() == normalized ||
            model.repoID.lowercased() == normalized ||
            "recommended:\(model.id.lowercased())" == normalized
        }
    }

    private func rank(_ tier: RecommendedModel.Tier) -> Int {
        switch tier {
        case .fast: 0
        case .balanced: 1
        case .quality: 2
        }
    }

    public static let defaultModels: [RecommendedModel] = [
        RecommendedModel(
            id: "fast-chat",
            title: "Qwen 0.5B Chat",
            repoID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            profile: .chat,
            tier: .fast,
            memoryHint: "4 GB+",
            sizeHint: "~0.4 GB",
            summary: "Smallest good default for quick local chat."
        ),
        RecommendedModel(
            id: "balanced-chat",
            title: "Llama 3.2 3B Chat",
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            profile: .chat,
            tier: .balanced,
            memoryHint: "8 GB+",
            sizeHint: "~1.8 GB",
            summary: "Balanced quality and speed for daily use."
        ),
        RecommendedModel(
            id: "quality-chat",
            title: "Qwen 2.5 7B Chat",
            repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            profile: .chat,
            tier: .quality,
            memoryHint: "16 GB+",
            sizeHint: "~4.3 GB",
            summary: "Stronger general chat quality on Apple Silicon."
        ),
        RecommendedModel(
            id: "fast-code",
            title: "Qwen 0.5B Coder",
            repoID: "mlx-community/Qwen2.5-Coder-0.5B-Instruct-4bit",
            profile: .code,
            tier: .fast,
            memoryHint: "4 GB+",
            sizeHint: "~0.4 GB",
            summary: "Fast coding assistant for lightweight tasks."
        ),
        RecommendedModel(
            id: "quality-code",
            title: "Qwen 7B Coder",
            repoID: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            profile: .code,
            tier: .quality,
            memoryHint: "16 GB+",
            sizeHint: "~4.3 GB",
            summary: "Best current coding preset in the built-in list."
        )
    ]
}
