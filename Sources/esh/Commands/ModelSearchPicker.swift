import Foundation
import Darwin
import EshCore

enum ModelSearchPicker {
    static func pick(
        title: String,
        subtitle: String,
        results: [ModelSearchResult]
    ) throws -> ModelSearchResult {
        guard !results.isEmpty else {
            throw StoreError.invalidManifest("No models available to choose from.")
        }

        if isatty(STDIN_FILENO) == 0 || isatty(STDOUT_FILENO) == 0 {
            printChoices(results)
            throw StoreError.invalidManifest("Multiple matches found. Re-run in an interactive terminal or use an exact repo id.")
        }

        let picker = InteractiveListPicker()
        let items = results.map { result in
            let kind = result.backend?.rawValue ?? result.tags.first ?? "-"
            let date = result.updatedAt.map(dateFormatter.string(from:)) ?? "-"
            let downloads = result.downloads.map(compactNumber(_:)) ?? "-"
            return InteractiveListPicker.Item(
                title: result.displayName,
                detail: "\(kind) | \(date) | \(downloads)"
            )
        }

        switch picker.pick(
            title: title,
            subtitle: subtitle,
            items: items,
            primaryHint: "Enter select"
        ) {
        case .selected(let index):
            return results[index]
        default:
            throw StoreError.invalidManifest("Selection cancelled.")
        }
    }

    private static func printChoices(_ results: [ModelSearchResult]) {
        print("no  model                              kind       date      downloads")
        for (offset, result) in results.enumerated() {
            let row = [
                pad("\(offset + 1).", width: 3),
                pad(result.displayName, width: 34),
                pad(result.backend?.rawValue ?? result.tags.first ?? "-", width: 10),
                pad(result.updatedAt.map(dateFormatter.string(from:)) ?? "-", width: 9),
                result.downloads.map(compactNumber(_:)) ?? "-"
            ].joined(separator: " ")
            print(row)
        }
    }

    private static func pad(_ value: String, width: Int) -> String {
        let truncated = truncate(value, limit: width)
        if truncated.count >= width {
            return truncated
        }
        return truncated + String(repeating: " ", count: width - truncated.count)
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        guard limit > 1 else { return String(value.prefix(limit)) }
        return String(value.prefix(limit - 1)) + "…"
    }

    private static func compactNumber(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}
