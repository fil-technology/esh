import Foundation

public struct HuggingFaceModelCatalog: ModelCatalog, Sendable {
    private struct SearchEntry: Decodable {
        let id: String
        let pipelineTag: String?
        let tags: [String]?
        let downloads: Int?
        let likes: Int?
        let libraryName: String?
        let lastModified: Date?
        let siblings: [Sibling]?
        let cardData: CardData?

        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
        }

        struct CardData: Decodable {
            let summary: String?
            let license: String?
        }
    }

    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func search(query: String, limit: Int) async throws -> [ModelSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            .init(name: "search", value: trimmed),
            .init(name: "apps", value: "mlx-lm"),
            .init(name: "limit", value: String(max(1, limit))),
            .init(name: "sort", value: "downloads"),
            .init(name: "direction", value: "-1"),
            .init(name: "full", value: "true"),
            .init(name: "cardData", value: "true")
        ]

        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StoreError.invalidManifest("Failed to search Hugging Face: HTTP \(http.statusCode).")
        }

        let entries = try decoder.decode([SearchEntry].self, from: data)
        return entries
            .prefix(limit)
            .map { entry in
                ModelSearchResult(
                    id: entry.id,
                    source: .huggingFace,
                    modelSource: ModelSource(kind: .huggingFace, reference: entry.id),
                    displayName: entry.id,
                    summary: entry.cardData?.summary,
                    backend: .mlx,
                    sizeBytes: totalSize(for: entry.siblings),
                    tags: normalizedTags(for: entry),
                    downloads: entry.downloads,
                    likes: entry.likes,
                    updatedAt: entry.lastModified
                )
            }
    }

    private func totalSize(for siblings: [SearchEntry.Sibling]?) -> Int64? {
        guard let siblings else { return nil }
        let sizes = siblings.compactMap(\.size)
        guard !sizes.isEmpty else { return nil }
        return sizes.reduce(0, +)
    }

    private func normalizedTags(for entry: SearchEntry) -> [String] {
        var tags = entry.tags ?? []
        if let pipelineTag = entry.pipelineTag, tags.contains(pipelineTag) == false {
            tags.insert(pipelineTag, at: 0)
        }
        if let license = entry.cardData?.license, tags.contains(license) == false {
            tags.append(license)
        }
        return Array(tags.prefix(8))
    }
}
