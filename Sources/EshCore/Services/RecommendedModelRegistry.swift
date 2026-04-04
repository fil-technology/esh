import Foundation

public struct RecommendedModelRegistry: Sendable {
    private let models: [RecommendedModel]

    public init(models: [RecommendedModel] = RecommendedModelRegistry.defaultModels) {
        self.models = models
    }

    public func list(
        profile: RecommendedModel.Profile? = nil,
        tier: RecommendedModel.Tier? = nil,
        backend: BackendKind? = nil,
        tag: String? = nil
    ) -> [RecommendedModel] {
        let normalizedTag = tag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return models
            .filter { model in
                if let profile, model.profile != profile {
                    return false
                }
                if let tier, model.tier != tier {
                    return false
                }
                if let backend, model.backend != backend {
                    return false
                }
                if let normalizedTag {
                    return model.tags.contains { $0.lowercased() == normalizedTag }
                }
                return true
            }
            .sorted(by: isOrderedBefore)
    }

    public func resolve(alias: String) -> RecommendedModel? {
        let normalized = alias.lowercased()
        return models.first { model in
            model.id.lowercased() == normalized ||
            model.repoID.lowercased() == normalized ||
            model.title.lowercased() == normalized ||
            "recommended:\(model.id.lowercased())" == normalized
        }
    }

    private func isOrderedBefore(_ lhs: RecommendedModel, _ rhs: RecommendedModel) -> Bool {
        if lhs.tier != rhs.tier {
            return lhs.tier.sortRank < rhs.tier.sortRank
        }
        return lhs.sortOrder < rhs.sortOrder
    }

    public static let defaultModels: [RecommendedModel] = [
        RecommendedModel(
            id: "mistral-small-24b",
            title: "Mistral Small 24B Instruct (2501)",
            repoID: "mlx-community/Mistral-Small-24B-Instruct-2501-4bit",
            parameterSize: "24B",
            quantization: "4-bit",
            profile: .code,
            tier: .good,
            estimatedMemoryGB: 13.5,
            totalDiskSizeGB: 13.3,
            tags: ["general-purpose", "coding", "agentic"],
            summary: "Balanced built-in default for everyday chat, coding, and agentic tasks.",
            sortOrder: 0
        ),
        RecommendedModel(
            id: "deepseek-r1-qwen-14b",
            title: "DeepSeek R1 Distill Qwen 14B",
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit",
            parameterSize: "14B",
            quantization: "4-bit",
            profile: .chat,
            tier: .good,
            estimatedMemoryGB: 8.3,
            totalDiskSizeGB: 8.3,
            tags: ["reasoning", "fast-inference", "logic"],
            summary: "Reasoning-focused sweet spot model with faster inference than larger R1 distills.",
            sortOrder: 1
        ),
        RecommendedModel(
            id: "qwen-3-5-9b-optiq",
            title: "Qwen 3.5 9B OptiQ",
            repoID: "mlx-community/Qwen3.5-9B-OptiQ-4bit",
            parameterSize: "9B",
            quantization: "4-bit",
            profile: .chat,
            tier: .good,
            estimatedMemoryGB: 5.4,
            totalDiskSizeGB: 5.1,
            tags: ["instruction-following", "vision-language", "high-throughput"],
            summary: "High-throughput mid-size option with strong instruction following and VLM support.",
            sortOrder: 2
        ),
        RecommendedModel(
            id: "llama-3-1-8b",
            title: "Llama 3.1 8B Instruct",
            repoID: "mlx-community/Llama-3.1-8B-Instruct-4bit",
            parameterSize: "8B",
            quantization: "4-bit",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 4.8,
            totalDiskSizeGB: 4.5,
            tags: ["agentic", "general-purpose", "roleplay"],
            summary: "Efficient general-purpose small model for broad local usage.",
            sortOrder: 3
        ),
        RecommendedModel(
            id: "qwen-2-5-coder-7b",
            title: "Qwen 2.5 Coder 7B Instruct",
            repoID: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            parameterSize: "7B",
            quantization: "4-bit",
            profile: .code,
            tier: .small,
            estimatedMemoryGB: 4.5,
            totalDiskSizeGB: 4.3,
            tags: ["coding", "lightweight", "autocomplete"],
            summary: "Lightweight coding recommendation with a strong quality-to-efficiency tradeoff.",
            sortOrder: 4
        ),
        RecommendedModel(
            id: "llama-3-2-3b",
            title: "Llama 3.2 3B Instruct",
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            parameterSize: "3B",
            quantization: "4-bit",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 2.1,
            totalDiskSizeGB: 1.8,
            tags: ["fast-inference", "embedded-tasks", "summarization"],
            summary: "Very fast lightweight choice for summarization and small-device workflows.",
            sortOrder: 5
        ),
        RecommendedModel(
            id: "qwen-2-5-0-5b",
            title: "Qwen 2.5 0.5B Instruct",
            repoID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            parameterSize: "0.5B",
            quantization: "4-bit",
            profile: .chat,
            tier: .tiny,
            estimatedMemoryGB: 0.6,
            totalDiskSizeGB: 0.4,
            tags: ["starter", "always-on", "fast-inference"],
            summary: "Tiny starter model for instant first-run chat and lightweight assistant loops.",
            sortOrder: 6
        ),
        RecommendedModel(
            id: "qwen-3-5-0-8b-optiq",
            title: "Qwen 3.5 0.8B OptiQ",
            repoID: "mlx-community/Qwen3.5-0.8B-OptiQ-4bit",
            parameterSize: "0.8B",
            quantization: "4-bit",
            profile: .chat,
            tier: .tiny,
            estimatedMemoryGB: 0.8,
            totalDiskSizeGB: 0.6,
            tags: ["background-agent", "ultra-fast", "formatting"],
            summary: "Ultra-light model for background helpers, formatting, and fast automation loops.",
            sortOrder: 7
        ),
        RecommendedModel(
            id: "qwen-3-5-27b-opus-distilled",
            title: "Qwen 3.5 27B (Opus Distilled)",
            repoID: "mlx-community/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit",
            parameterSize: "27B",
            quantization: "4-bit",
            profile: .chat,
            tier: .max,
            estimatedMemoryGB: 15.5,
            totalDiskSizeGB: 14.8,
            tags: ["reasoning", "distilled", "chain-of-thought"],
            summary: "Large distilled reasoning preset aimed at higher-quality chain-of-thought style tasks.",
            sortOrder: 8
        ),
        RecommendedModel(
            id: "deepseek-r1-qwen-32b",
            title: "DeepSeek R1 Distill Qwen 32B",
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit",
            parameterSize: "32B",
            quantization: "4-bit",
            profile: .chat,
            tier: .max,
            estimatedMemoryGB: 19.5,
            totalDiskSizeGB: 18.4,
            tags: ["math", "logic", "chain-of-thought"],
            summary: "Large reasoning recommendation tuned for math and logic heavy workloads.",
            sortOrder: 9
        ),
        RecommendedModel(
            id: "qwen-2-5-coder-32b",
            title: "Qwen 2.5 Coder 32B Instruct",
            repoID: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
            parameterSize: "32B",
            quantization: "4-bit",
            profile: .code,
            tier: .max,
            estimatedMemoryGB: 19.5,
            totalDiskSizeGB: 18.4,
            tags: ["coding", "development", "agentic"],
            summary: "Largest built-in coding preset for advanced development and agentic tasks.",
            sortOrder: 10
        ),
        RecommendedModel(
            id: "llama-3-2-3b-gguf",
            title: "Llama 3.2 3B Instruct GGUF",
            repoID: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            parameterSize: "3B",
            quantization: "Q4_K_M",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 2.2,
            totalDiskSizeGB: 2.0,
            tags: ["gguf", "starter", "fast-inference"],
            summary: "GGUF starter preset for lightweight local chat through llama.cpp.",
            backend: .gguf,
            sortOrder: 11
        ),
        RecommendedModel(
            id: "qwen-2-5-coder-7b-gguf",
            title: "Qwen 2.5 Coder 7B Instruct GGUF",
            repoID: "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF",
            parameterSize: "7B",
            quantization: "Q4_K_M",
            profile: .code,
            tier: .small,
            estimatedMemoryGB: 4.6,
            totalDiskSizeGB: 4.3,
            tags: ["gguf", "coding", "lightweight"],
            summary: "GGUF coding preset with a strong quality-to-speed tradeoff.",
            backend: .gguf,
            sortOrder: 12
        ),
        RecommendedModel(
            id: "deepseek-r1-qwen-14b-gguf",
            title: "DeepSeek R1 Distill Qwen 14B GGUF",
            repoID: "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF",
            parameterSize: "14B",
            quantization: "Q4_K_M",
            profile: .chat,
            tier: .good,
            estimatedMemoryGB: 9.8,
            totalDiskSizeGB: 7.9,
            tags: ["gguf", "reasoning", "logic"],
            summary: "GGUF reasoning preset for llama.cpp-backed local chat.",
            backend: .gguf,
            sortOrder: 13
        )
    ]
}
