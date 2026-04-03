import Foundation

public enum ModelFeatureClassifier {
    public static func features(for recommendedModel: RecommendedModel) -> [String] {
        var result = recommendedModel.tags
        switch recommendedModel.profile {
        case .chat:
            result.append("chat")
        case .code:
            result.append("code")
        }
        return dedupe(
            result + features(
                name: recommendedModel.title,
                reference: recommendedModel.repoID,
                tags: recommendedModel.tags
            )
        )
    }

    public static func features(for install: ModelInstall) -> [String] {
        features(
            name: install.spec.displayName,
            reference: install.spec.source.reference,
            tags: [install.backendFormat]
        )
    }

    public static func features(for searchResult: ModelSearchResult) -> [String] {
        features(
            name: searchResult.displayName,
            reference: searchResult.modelSource.reference,
            tags: searchResult.tags
        )
    }

    private static func features(name: String, reference: String, tags: [String]) -> [String] {
        let haystack = ([name, reference] + tags).joined(separator: " ").lowercased()
        var result: [String] = []

        if haystack.contains("instruct") || haystack.contains("chat") {
            result.append("chat")
        }
        if haystack.contains("coder") || haystack.contains("code") {
            result.append("code")
        }
        if haystack.contains("reason") || haystack.contains("think") || haystack.contains("r1") {
            result.append("reason")
        }
        if haystack.contains("vl") || haystack.contains("vision") || haystack.contains("multimodal") {
            result.append("vision")
        }
        if haystack.contains("32k") || haystack.contains("64k") || haystack.contains("128k") || haystack.contains("long") {
            result.append("long")
        }

        return dedupe(result)
    }

    private static func dedupe(_ features: [String]) -> [String] {
        var seen = Set<String>()
        return features.filter { seen.insert($0).inserted }
    }
}
