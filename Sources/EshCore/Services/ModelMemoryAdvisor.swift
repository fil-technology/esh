import Foundation

public enum ModelMemoryAdvisor {
    public static func requiredMemoryBytes(
        recommendedModel: RecommendedModel?,
        searchResult: ModelSearchResult?
    ) -> Int64? {
        if let recommendedModel {
            return gibibytes(recommendedModel.estimatedMemoryGB)
        }

        guard let sizeBytes = searchResult?.sizeBytes else {
            return nil
        }

        switch sizeBytes {
        case ..<1_000_000_000:
            return gibibytes(4.0)
        case ..<3_000_000_000:
            return gibibytes(8.0)
        case ..<5_500_000_000:
            return gibibytes(16.0)
        case ..<9_000_000_000:
            return gibibytes(24.0)
        default:
            return gibibytes(32.0)
        }
    }

    public static func requiredDiskBytes(
        recommendedModel: RecommendedModel?,
        searchResult: ModelSearchResult?
    ) -> Int64? {
        if let recommendedModel {
            return diskBudget(for: gibibytes(recommendedModel.totalDiskSizeGB))
        }

        guard let sizeBytes = searchResult?.sizeBytes else {
            return nil
        }
        return diskBudget(for: sizeBytes)
    }

    private static func diskBudget(for sizeBytes: Int64) -> Int64 {
        let overhead = max(sizeBytes / 10, 512 * 1_024 * 1_024)
        return sizeBytes + overhead
    }

    private static func gibibytes(_ value: Double) -> Int64 {
        Int64(value * 1_024 * 1_024 * 1_024)
    }

}
