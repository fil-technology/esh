import Foundation

public struct ContextReadService: Sendable {
    public init() {}

    public func readSymbol(
        _ symbolName: String,
        from index: ContextIndex,
        workspaceRootURL: URL
    ) throws -> SymbolReadResult {
        let candidates = index.symbols.filter {
            $0.name == symbolName || $0.name.hasSuffix(".\(symbolName)") || $0.name.localizedCaseInsensitiveContains(symbolName)
        }
        guard let symbol = candidates.sorted(by: preferredSymbolOrder).first else {
            throw StoreError.notFound("Symbol \(symbolName) not found in context index.")
        }
        let fileURL = workspaceRootURL.appendingPathComponent(symbol.filePath)
        let range = SourceRange(lineStart: max(symbol.lineStart - 3, 1), lineEnd: symbol.lineEnd + 12)
        let fileRead = try readFile(symbol.filePath, range: range, workspaceRootURL: workspaceRootURL)
        return SymbolReadResult(symbol: symbol, fileURL: fileURL, range: range, lines: fileRead.lines)
    }

    public func readFile(
        _ relativePath: String,
        range: SourceRange,
        workspaceRootURL: URL
    ) throws -> FileReadResult {
        let fileURL = try resolveFileURL(relativePath, workspaceRootURL: workspaceRootURL)
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        let startIndex = max(range.lineStart - 1, 0)
        let endIndex = min(range.lineEnd, lines.count)
        let snippet = Array(lines[startIndex..<endIndex])
        return FileReadResult(fileURL: fileURL, range: range, lines: snippet)
    }

    public func findReferences(
        _ symbolName: String,
        in index: ContextIndex,
        workspaceRootURL: URL,
        limit: Int = 20
    ) throws -> [FileReadResult] {
        let needle = symbolName.split(separator: ".").last.map(String.init) ?? symbolName
        var matches: [FileReadResult] = []

        for file in index.files {
            let fileURL = workspaceRootURL.appendingPathComponent(file.path)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(needle) {
                let range = SourceRange(lineStart: max(index + 1 - 2, 1), lineEnd: min(index + 1 + 2, lines.count))
                let snippet = Array(lines[(range.lineStart - 1)..<range.lineEnd])
                matches.append(FileReadResult(fileURL: fileURL, range: range, lines: snippet))
                if matches.count >= limit {
                    return matches
                }
            }
        }

        return matches
    }

    public func readRelated(
        _ target: String,
        in index: ContextIndex,
        workspaceRootURL: URL,
        limit: Int = 5
    ) throws -> [FileReadResult] {
        let symbolMatches = index.symbols.filter {
            $0.name == target || $0.name.hasSuffix(".\(target)") || $0.name.localizedCaseInsensitiveContains(target)
        }
        let filePath: String
        if let symbol = symbolMatches.first {
            filePath = symbol.filePath
        } else if index.files.contains(where: { $0.path == target }) {
            filePath = target
        } else {
            throw StoreError.notFound("No related context found for \(target).")
        }

        let neighbors = Set(
            index.edges.compactMap { edge -> String? in
                if edge.fromPath == filePath {
                    return edge.toPath
                }
                if edge.toPath == filePath {
                    return edge.fromPath
                }
                return nil
            } + [filePath]
        )

        return try neighbors.sorted().prefix(limit).map { path in
            try readFile(path, range: SourceRange(lineStart: 1, lineEnd: 40), workspaceRootURL: workspaceRootURL)
        }
    }

    private func preferredSymbolOrder(lhs: SymbolNode, rhs: SymbolNode) -> Bool {
        if lhs.name.count == rhs.name.count {
            if lhs.filePath == rhs.filePath {
                return lhs.lineStart < rhs.lineStart
            }
            return lhs.filePath < rhs.filePath
        }
        return lhs.name.count < rhs.name.count
    }

    private func resolveFileURL(_ relativePath: String, workspaceRootURL: URL) throws -> URL {
        let directURL = workspaceRootURL.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }

        let suffix = "/" + relativePath
        let targetName = URL(fileURLWithPath: relativePath).lastPathComponent
        guard let enumerator = FileManager.default.enumerator(
            at: workspaceRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw StoreError.notFound("File \(relativePath) not found in workspace \(workspaceRootURL.path).")
        }

        for case let fileURL as URL in enumerator {
            guard let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegular == true else {
                continue
            }
            if fileURL.lastPathComponent == targetName || fileURL.path.hasSuffix(suffix) {
                return fileURL
            }
        }

        throw StoreError.notFound("File \(relativePath) not found in workspace \(workspaceRootURL.path).")
    }
}
