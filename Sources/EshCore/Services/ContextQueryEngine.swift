import Foundation

public struct ContextQueryEngine: Sendable {
    public init() {}

    public func query(
        _ query: String,
        in index: ContextIndex,
        limit: Int = 10
    ) -> [RankedContextResult] {
        let terms = tokenize(query)
        let changedFiles = changedFileSet(workspaceRootPath: index.workspaceRootPath)
        let symbolGroups = Dictionary(grouping: index.symbols, by: \.filePath)
        let inboundEdges = Dictionary(grouping: index.edges, by: \.toPath)

        let ranked = index.files.compactMap { file -> RankedContextResult? in
            var score = 0.0
            var reasons: [String] = []
            let pathLower = file.path.lowercased()

            for term in terms {
                if pathLower.contains(term) {
                    score += pathLower.hasSuffix(term) ? 8 : 5
                    reasons.append("filename/path match: \(term)")
                }
            }

            let relatedSymbols = (symbolGroups[file.path] ?? []).filter { symbol in
                let name = symbol.name.lowercased()
                return terms.contains { name.contains($0) }
            }
            if relatedSymbols.isEmpty == false {
                score += Double(relatedSymbols.count) * 7
                reasons.append("symbol match")
            }

            if changedFiles.contains(file.path) {
                score += 3
                reasons.append("uncommitted changes")
            }

            if let lastModifiedAt = file.lastModifiedAt {
                let age = Date().timeIntervalSince(lastModifiedAt)
                if age < 60 * 60 * 24 * 7 {
                    score += 2
                    reasons.append("recently edited")
                }
            }

            let adjacencyBoost = Double((inboundEdges[file.path] ?? []).count)
            if adjacencyBoost > 0 {
                score += min(adjacencyBoost, 3)
                reasons.append("dependency adjacency")
            }

            guard score > 0 else {
                return nil
            }

            let ranges = relatedSymbols.prefix(3).map {
                SourceRange(lineStart: max($0.lineStart - 3, 1), lineEnd: $0.lineEnd + 8)
            }

            return RankedContextResult(
                filePath: file.path,
                score: score,
                reasons: Array(NSOrderedSet(array: reasons)) as? [String] ?? reasons,
                suggestedRanges: ranges,
                relatedSymbols: relatedSymbols.prefix(5).map(\.name)
            )
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.filePath < rhs.filePath
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func tokenize(_ query: String) -> [String] {
        let lowercase = query.lowercased()
        let components = lowercase.split { $0.isWhitespace || $0.isPunctuation }
        return components.map(String.init).filter { $0.count >= 2 }
    }

    private func changedFileSet(workspaceRootPath: String) -> Set<String> {
        let output = try? ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "-C", workspaceRootPath, "status", "--porcelain"]
        )
        guard let output, output.exitCode == 0 else {
            return []
        }
        let lines = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n")
        return Set(lines.compactMap { line in
            let trimmed = line.dropFirst(3)
            return trimmed.isEmpty ? nil : String(trimmed)
        })
    }
}
