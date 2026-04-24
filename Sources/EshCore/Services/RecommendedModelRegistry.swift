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
            id: "qwen-3-5-9b",
            title: "Qwen 3.5 9B",
            repoID: "mlx-community/Qwen3.5-9B-MLX-4bit",
            parameterSize: "9B",
            quantization: "4-bit",
            profile: .chat,
            tier: .good,
            estimatedMemoryGB: 5.6,
            totalDiskSizeGB: 5.2,
            tags: ["default", "balanced", "general-purpose"],
            summary: "Balanced first-choice local assistant for everyday chat, drafting, and research.",
            sortOrder: 0
        ),
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
            sortOrder: 1
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
            sortOrder: 2
        ),
        RecommendedModel(
            id: "deepseek-r1-qwen-7b",
            title: "DeepSeek R1 Distill Qwen 7B",
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
            parameterSize: "7B",
            quantization: "4-bit",
            profile: .chat,
            tier: .good,
            estimatedMemoryGB: 4.8,
            totalDiskSizeGB: 4.4,
            tags: ["reasoning", "compact", "logic"],
            summary: "Smaller reasoning-focused preset for deliberate math, logic, and structured problem solving.",
            sortOrder: 3
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
            sortOrder: 4
        ),
        RecommendedModel(
            id: "phi-4-mini-reasoning",
            title: "Phi-4 Mini Reasoning",
            repoID: "mlx-community/Phi-4-mini-reasoning-4bit",
            parameterSize: "4B",
            quantization: "4-bit",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 3.2,
            totalDiskSizeGB: 2.9,
            tags: ["reasoning", "small", "structured-output"],
            summary: "Compact reasoning helper for logic-heavy prompts, structured outputs, and short code bursts.",
            sortOrder: 5
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
            sortOrder: 6
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
            sortOrder: 7
        ),
        RecommendedModel(
            id: "phi-3-5-mini-instruct",
            title: "Phi 3.5 Mini Instruct",
            repoID: "mlx-community/Phi-3.5-mini-instruct-4bit",
            parameterSize: "3.8B",
            quantization: "4-bit",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 2.8,
            totalDiskSizeGB: 2.5,
            tags: ["compact", "general-purpose", "helper"],
            summary: "Lean helper preset for lightweight drafting, Q&A, and quick tool-oriented turns.",
            sortOrder: 8
        ),
        RecommendedModel(
            id: "qwen-3-5-2b",
            title: "Qwen 3.5 2B",
            repoID: "mlx-community/Qwen3.5-2B-MLX-4bit",
            parameterSize: "2B",
            quantization: "4-bit",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 1.7,
            totalDiskSizeGB: 1.3,
            tags: ["fast-inference", "lightweight", "general-purpose"],
            summary: "Fast small generalist when you want noticeably better quality than tiny models without much extra cost.",
            sortOrder: 9
        ),
        RecommendedModel(
            id: "gemma-4-e4b-it",
            title: "Gemma 4 E4B-it",
            repoID: "mlx-community/gemma-4-e4b-it-4bit",
            parameterSize: "4B",
            quantization: "4-bit",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 3.4,
            totalDiskSizeGB: 3.0,
            tags: ["gemma", "compact", "general-purpose"],
            summary: "Compact Gemma preset with a useful balance for chat, drafting, and quick research loops.",
            sortOrder: 10
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
            sortOrder: 11
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
            sortOrder: 12
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
            sortOrder: 13
        ),
        RecommendedModel(
            id: "qwen-3-5-0-8b",
            title: "Qwen 3.5 0.8B",
            repoID: "mlx-community/Qwen3.5-0.8B-MLX-4bit",
            parameterSize: "0.8B",
            quantization: "4-bit",
            profile: .chat,
            tier: .tiny,
            estimatedMemoryGB: 0.9,
            totalDiskSizeGB: 0.7,
            tags: ["tiny", "ultra-fast", "helper"],
            summary: "Tiny helper preset for ultra-fast chat, formatting, and background assistant tasks.",
            sortOrder: 14
        ),
        RecommendedModel(
            id: "gemma-4-e2b-it",
            title: "Gemma 4 E2B-it",
            repoID: "mlx-community/gemma-4-e2b-it-4bit",
            parameterSize: "2B",
            quantization: "4-bit",
            profile: .chat,
            tier: .tiny,
            estimatedMemoryGB: 1.6,
            totalDiskSizeGB: 1.2,
            tags: ["tiny", "gemma", "helper"],
            summary: "Small Gemma helper for lightweight chat and short drafting turns on tighter memory budgets.",
            sortOrder: 15
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
            sortOrder: 16
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
            sortOrder: 17
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
            sortOrder: 18
        ),
        RecommendedModel(
            id: "qwen-3-5-9b-gguf",
            title: "Qwen 3.5 9B GGUF",
            repoID: "bartowski/Qwen_Qwen3.5-9B-GGUF",
            parameterSize: "9B",
            quantization: "Q4_K_M",
            profile: .chat,
            tier: .good,
            estimatedMemoryGB: 6.2,
            totalDiskSizeGB: 5.5,
            tags: ["gguf", "default", "balanced"],
            summary: "GGUF fallback for a strong all-around local assistant through llama.cpp.",
            backend: .gguf,
            sortOrder: 19
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
            sortOrder: 20
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
            sortOrder: 21
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
            sortOrder: 22
        ),
        RecommendedModel(
            id: "deepseek-r1-qwen-7b-gguf",
            title: "DeepSeek R1 Distill Qwen 7B GGUF",
            repoID: "bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF",
            parameterSize: "7B",
            quantization: "Q4_K_M",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 5.0,
            totalDiskSizeGB: 4.6,
            tags: ["gguf", "reasoning", "compact"],
            summary: "Compact GGUF reasoning preset when you want a smaller deliberate model through llama.cpp.",
            backend: .gguf,
            sortOrder: 23
        ),
        RecommendedModel(
            id: "phi-4-mini-reasoning-gguf",
            title: "Phi 4 Mini Reasoning GGUF",
            repoID: "unsloth/Phi-4-mini-reasoning-GGUF",
            parameterSize: "4B",
            quantization: "Q4_K_M",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 3.4,
            totalDiskSizeGB: 3.1,
            tags: ["gguf", "reasoning", "small"],
            summary: "Compact GGUF reasoning helper for logic-heavy prompts and structured outputs.",
            backend: .gguf,
            sortOrder: 24
        ),
        RecommendedModel(
            id: "phi-3-5-mini-instruct-gguf",
            title: "Phi 3.5 Mini Instruct GGUF",
            repoID: "bartowski/Phi-3.5-mini-instruct-GGUF",
            parameterSize: "3.8B",
            quantization: "Q4_K_M",
            profile: .chat,
            tier: .small,
            estimatedMemoryGB: 3.0,
            totalDiskSizeGB: 2.7,
            tags: ["gguf", "compact", "helper"],
            summary: "Lean GGUF helper preset for lightweight drafting, Q&A, and quick tool-oriented turns.",
            backend: .gguf,
            sortOrder: 25
        )
    ]
}
