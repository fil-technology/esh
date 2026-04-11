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
        let recentlyTouchedFiles = recentlyTouchedFileSet(workspaceRootPath: index.workspaceRootPath)
        let symbolGroups = Dictionary(grouping: index.symbols, by: \.filePath)
        let inboundEdges = Dictionary(grouping: index.edges, by: \.toPath)

        let ranked = index.files.compactMap { file -> RankedContextResult? in
            var score = 0.0
            var reasons: [String] = []
            let pathLower = file.path.lowercased()
            let basename = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
            let basenameLower = basename.lowercased()
            let pathTokens = tokenSet(from: file.path)
            let basenameTokens = tokenSet(from: basename)
            let symbolTokens = Set((symbolGroups[file.path] ?? []).flatMap { tokenSet(from: $0.name) })
            let importTokens = Set(file.imports.flatMap { tokenSet(from: $0) })
            let contentTokens = Set(file.searchTokens)
            let matchedPathTerms = Set(terms.filter { pathTokens.contains($0) })
            let matchedBasenameTerms = Set(terms.filter { basenameTokens.contains($0) })
            let matchedSymbolTerms = Set(terms.filter { symbolTokens.contains($0) })
            let matchedImportTerms = Set(terms.filter { importTokens.contains($0) })
            let matchedContentTerms = Set(terms.filter { contentTokens.contains($0) })

            for term in terms {
                if pathLower.contains(term) {
                    score += pathLower.hasSuffix(term) ? 6 : 3
                    reasons.append("filename/path match: \(term)")
                }
            }

            let relatedSymbols = (symbolGroups[file.path] ?? []).filter { symbol in
                let name = symbol.name.lowercased()
                return terms.contains { name.contains($0) }
            }
            if relatedSymbols.isEmpty == false {
                score += Double(relatedSymbols.count) * 5
                reasons.append("symbol match")
            }

            if matchedBasenameTerms.isEmpty == false {
                score += Double(matchedBasenameTerms.count) * 8
                reasons.append("basename token match")
            }

            if matchedPathTerms.isEmpty == false {
                score += Double(matchedPathTerms.count) * 3
                reasons.append("path token coverage")
            }

            if matchedSymbolTerms.isEmpty == false {
                score += Double(matchedSymbolTerms.count) * 9
                reasons.append("symbol token coverage")
            }

            if matchedImportTerms.isEmpty == false {
                score += Double(matchedImportTerms.count) * 2
                reasons.append("import token match")
            }

            if matchedContentTerms.isEmpty == false {
                score += Double(matchedContentTerms.count) * 7
                reasons.append("content token match")
            }

            let uiIntentTerms: Set<String> = ["button", "toolbar", "label", "sheet", "navigation", "list", "view"]
            let actionTerms: Set<String> = ["add", "delete", "edit", "toggle", "save", "open", "show"]
            let matchedUIIntentTerms = Set(terms.filter { uiIntentTerms.contains($0) })
            let matchedActionTerms = Set(terms.filter { actionTerms.contains($0) })

            if file.imports.contains("SwiftUI"),
               matchedUIIntentTerms.isEmpty == false,
               matchedContentTerms.intersection(matchedUIIntentTerms).isEmpty == false {
                score += Double(matchedUIIntentTerms.count) * 6
                reasons.append("swiftui ui intent")
            }

            if file.imports.contains("SwiftUI"),
               matchedActionTerms.isEmpty == false,
               matchedContentTerms.intersection(matchedActionTerms).isEmpty == false {
                score += Double(matchedActionTerms.count) * 6
                reasons.append("swiftui action match")
            }

            if file.imports.contains("SwiftUI"), basenameLower.contains("view"), matchedUIIntentTerms.isEmpty == false {
                score += 4
                reasons.append("swiftui view file")
            }

            let matchedTerms = matchedPathTerms
                .union(matchedBasenameTerms)
                .union(matchedSymbolTerms)
                .union(matchedImportTerms)
                .union(matchedContentTerms)
            if terms.isEmpty == false {
                let coverage = Double(matchedTerms.count) / Double(terms.count)
                if coverage > 0 {
                    score += coverage * 18
                    reasons.append("term coverage")
                }
                if matchedTerms.count == terms.count {
                    score += 6
                    reasons.append("all query terms covered")
                }
            }

            if changedFiles.contains(file.path) {
                score += 3
                reasons.append("uncommitted changes")
            }

            if recentlyTouchedFiles.contains(file.path) {
                score += 2
                reasons.append("recent git history")
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

            if file.path.hasPrefix("Sources/") {
                score += 1.5
                reasons.append("source file")
            } else if file.path.hasPrefix("Tests/"), terms.contains("test") == false, terms.contains("tests") == false {
                score -= 2
                reasons.append("test file penalty")
            }

            if basename == "Contents" && file.path.hasSuffix(".json") {
                score -= 12
                reasons.append("metadata file penalty")
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
        tokenSet(from: query).sorted()
    }

    private func tokenSet(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "do", "does", "file", "files", "for", "from",
            "how", "i", "implemented", "in", "is", "it", "item", "items", "its", "located", "location",
            "me", "of", "on", "or", "show", "that", "the", "their", "this", "to", "what", "where",
            "which", "with", "you", "your"
        ]
        let separatedCamelCase = text.unicodeScalars.reduce(into: "") { partial, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), partial.isEmpty == false {
                partial.append(" ")
            }
            partial.append(Character(scalar))
        }
        let normalized = separatedCamelCase
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
        let components = normalized.split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
            .filter { $0.count >= 2 && stopWords.contains($0) == false }
        return Set(components)
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

    private func recentlyTouchedFileSet(workspaceRootPath: String) -> Set<String> {
        let output = try? ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "-C", workspaceRootPath, "log", "--since=90.days", "--name-only", "--format="]
        )
        guard let output, output.exitCode == 0 else {
            return []
        }
        let files = String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.isEmpty == false }
        return Set(files)
    }
}
