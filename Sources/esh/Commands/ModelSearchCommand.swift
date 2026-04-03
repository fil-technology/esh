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

        for result in results {
            let installedMarker = result.isInstalled ? "installed" : "-"
            let source = result.source == .huggingFace ? "hf" : "local"
            let size = result.sizeBytes.map(ByteFormatting.string(for:)) ?? "-"
            let downloads = result.downloads.map(String.init) ?? "-"
            let installID = result.installedModelID ?? "-"
            let summary = result.summary?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            print("\(source)\t\(installedMarker)\t\(result.id)\t\(installID)\t\(size)\t\(downloads)")
            if !summary.isEmpty {
                print("  \(summary)")
            }
        }
    }
}
