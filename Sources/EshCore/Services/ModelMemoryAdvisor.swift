import Foundation

public enum ModelMemoryAdvisor {
    public static func requiredMemoryBytes(
        recommendedModel: RecommendedModel?,
        searchResult: ModelSearchResult?
    ) -> Int64? {
        if let recommendedModel {
            return parseMemoryHint(recommendedModel.memoryHint)
        }

        guard let sizeBytes = searchResult?.sizeBytes else {
            return nil
        }

        switch sizeBytes {
        case ..<1_000_000_000:
            return gibibytes(4)
        case ..<3_000_000_000:
            return gibibytes(8)
        case ..<5_500_000_000:
            return gibibytes(16)
        case ..<9_000_000_000:
            return gibibytes(24)
        default:
            return gibibytes(32)
        }
    }

    public static func requiredDiskBytes(
        recommendedModel: RecommendedModel?,
        searchResult: ModelSearchResult?
    ) -> Int64? {
        if let recommendedModel, let size = parseSizeHint(recommendedModel.sizeHint) {
            return diskBudget(for: size)
        }

        guard let sizeBytes = searchResult?.sizeBytes else {
            return nil
        }
        return diskBudget(for: sizeBytes)
    }

    private static func parseMemoryHint(_ value: String) -> Int64? {
        let digits = value.prefix { $0.isNumber }
        guard let gigabytes = Int64(digits) else { return nil }
        return gibibytes(gigabytes)
    }

    private static func parseSizeHint(_ value: String) -> Int64? {
        let normalized = value
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let parts = normalized.split(separator: " ")
        guard parts.count >= 2, let amount = Double(parts[0]) else { return nil }

        switch parts[1] {
        case "KB":
            return Int64(amount * 1_024)
        case "MB":
            return Int64(amount * 1_024 * 1_024)
        case "GB":
            return Int64(amount * 1_024 * 1_024 * 1_024)
        default:
            return nil
        }
    }

    private static func diskBudget(for sizeBytes: Int64) -> Int64 {
        let overhead = max(sizeBytes / 10, 512 * 1_024 * 1_024)
        return sizeBytes + overhead
    }

    private static func gibibytes(_ value: Int64) -> Int64 {
        value * 1_024 * 1_024 * 1_024
    }
}
