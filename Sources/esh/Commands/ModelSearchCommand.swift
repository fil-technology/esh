import Foundation
import EshCore

enum ModelSearchCommand {
    static func run(arguments: [String], service: ModelCatalogService) async throws {
        let sourceValue = CommandSupport.optionalValue(flag: "--source", in: arguments) ?? "all"
        guard let sourceFilter = ModelCatalogService.SourceFilter(rawValue: sourceValue) else {
            throw StoreError.invalidManifest("Unknown search source \(sourceValue). Use all, local, or hf.")
        }

        let limitValue = CommandSupport.optionalValue(flag: "--limit", in: arguments)
        let limit = limitValue.flatMap(Int.init) ?? 10
        let positional = CommandSupport.positionalArguments(in: arguments, knownFlags: ["--source", "--limit"])
        guard !positional.isEmpty else {
            throw StoreError.invalidManifest("Usage: esh model search <query> [--source all|local|hf] [--limit N]")
        }

        let query = positional.joined(separator: " ")
        let results = try await service.search(query: query, sourceFilter: sourceFilter, limit: limit)
        if results.isEmpty {
            print("No models found for \"\(query)\".")
            return
        }

        let rows = results.map(Row.init)
        print(Row.header.render())
        for row in rows {
            print(row.render())
        }
    }
}

private extension ModelSearchCommand {
    struct Row {
        static let header = Row(
            source: "src",
            state: "state",
            model: "model",
            kind: "kind",
            size: "size",
            downloads: "dl",
            updated: "date"
        )

        let source: String
        let state: String
        let model: String
        let kind: String
        let size: String
        let downloads: String
        let updated: String

        init(result: ModelSearchResult) {
            self.source = result.source == .huggingFace ? "hf" : "local"
            self.state = result.isInstalled ? "installed" : "-"
            self.model = result.displayName
            self.kind = Row.kindText(for: result)
            self.size = result.sizeBytes.map(ByteFormatting.string(for:)) ?? "-"
            self.downloads = result.downloads.map(Row.compactNumber(_:)) ?? "-"
            self.updated = result.updatedAt.map(Row.dateFormatter.string(from:)) ?? "-"
        }

        init(
            source: String,
            state: String,
            model: String,
            kind: String,
            size: String,
            downloads: String,
            updated: String
        ) {
            self.source = source
            self.state = state
            self.model = model
            self.kind = kind
            self.size = size
            self.downloads = downloads
            self.updated = updated
        }

        func render() -> String {
            [
                Row.pad(source, width: 6),
                Row.pad(state, width: 10),
                Row.pad(model, width: 34),
                Row.pad(kind, width: 10),
                Row.pad(size, width: 10),
                Row.pad(downloads, width: 8),
                Row.pad(updated, width: 10)
            ].joined(separator: " ")
        }

        private static func kindText(for result: ModelSearchResult) -> String {
            if let backend = result.backend?.rawValue, !backend.isEmpty {
                return backend
            }
            if let firstTag = result.tags.first, !firstTag.isEmpty {
                return firstTag
            }
            return "-"
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

        private static func pad(_ value: String, width: Int) -> String {
            let normalized = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = truncate(normalized, limit: width)
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

        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM"
            return formatter
        }()
    }
}
