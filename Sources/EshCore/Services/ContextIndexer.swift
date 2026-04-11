import Foundation

public struct ContextIndexer: Sendable {
    private let extractor: SymbolExtractor

    public init(extractor: SymbolExtractor = .init()) {
        self.extractor = extractor
    }

    public func buildIndex(workspaceRootURL: URL) throws -> ContextIndex {
        let fileURLs = try collectSourceFiles(workspaceRootURL: workspaceRootURL)
        var files: [FileNode] = []
        var symbols: [SymbolNode] = []
        var edges: [DependencyEdge] = []
        var symbolToPath: [String: String] = [:]
        var pendingImports: [(String, [String])] = []

        for fileURL in fileURLs {
            let relativePath = relativePath(for: fileURL, workspaceRootURL: workspaceRootURL)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let language = language(for: fileURL)
            let extraction = extractor.extractSymbols(from: content, relativePath: relativePath, language: language)
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let modifiedAt = attributes?[.modificationDate] as? Date
            let contentHash = Fingerprint.sha256([content])

            let fileNode = FileNode(
                path: relativePath,
                language: language,
                imports: extraction.imports,
                definedSymbols: extraction.symbols.map(\.name),
                searchTokens: searchTokens(from: content),
                lastModifiedAt: modifiedAt,
                contentHash: contentHash
            )
            files.append(fileNode)
            symbols.append(contentsOf: extraction.symbols)
            extraction.symbols.forEach { symbolToPath[$0.name] = relativePath }
            pendingImports.append((relativePath, extraction.imports))
        }

        for (fromPath, imports) in pendingImports {
            for entry in imports {
                if let target = symbolToPath[entry] {
                    edges.append(DependencyEdge(fromPath: fromPath, toPath: target, kind: "symbol"))
                } else if let target = resolveImportPath(entry, files: files) {
                    edges.append(DependencyEdge(fromPath: fromPath, toPath: target, kind: "import"))
                }
            }
        }

        return ContextIndex(
            workspaceRootPath: workspaceRootURL.path,
            builtAt: Date(),
            files: files.sorted { $0.path < $1.path },
            symbols: symbols.sorted { lhs, rhs in
                if lhs.filePath == rhs.filePath {
                    return lhs.lineStart < rhs.lineStart
                }
                return lhs.filePath < rhs.filePath
            },
            edges: Array(Set(edges)).sorted { lhs, rhs in
                if lhs.fromPath == rhs.fromPath {
                    return lhs.toPath < rhs.toPath
                }
                return lhs.fromPath < rhs.fromPath
            }
        )
    }

    private func collectSourceFiles(workspaceRootURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: workspaceRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let skippedDirectoryNames: Set<String> = [".git", ".build", ".swiftpm", ".venv", "node_modules", "dist", "build"]
        var urls: [URL] = []

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true {
                if skippedDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, language(for: url) != nil else {
                continue
            }
            urls.append(url)
        }

        return urls
    }

    private func relativePath(for fileURL: URL, workspaceRootURL: URL) -> String {
        let workspacePath = workspaceRootURL.path.hasSuffix("/") ? workspaceRootURL.path : workspaceRootURL.path + "/"
        if fileURL.path.hasPrefix(workspacePath) {
            return String(fileURL.path.dropFirst(workspacePath.count))
        }
        return fileURL.lastPathComponent
    }

    private func resolveImportPath(_ entry: String, files: [FileNode]) -> String? {
        let normalized = entry.replacingOccurrences(of: ".", with: "/")
        return files.first { file in
            file.path.hasSuffix("\(normalized).swift") ||
            file.path.hasSuffix("\(normalized).py") ||
            file.path.hasSuffix("\(normalized).ts") ||
            file.path.hasSuffix("\(normalized).js") ||
            file.path.hasSuffix("\(normalized).rs") ||
            file.path.contains(normalized)
        }?.path
    }

    private func language(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "swift":
            return "swift"
        case "py":
            return "python"
        case "js":
            return "javascript"
        case "ts", "tsx":
            return "typescript"
        case "rs":
            return "rust"
        default:
            return nil
        }
    }

    private func searchTokens(from content: String) -> [String] {
        let stopWords: Set<String> = [
            "import", "func", "struct", "class", "enum", "let", "var", "return", "public", "private",
            "internal", "static", "self", "true", "false", "guard", "else", "case", "switch", "default",
            "init", "extension", "throws", "async", "await", "try", "nil", "void", "line", "lines"
        ]
        let separatedCamelCase = content.unicodeScalars.reduce(into: "") { partial, scalar in
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
        let tokens = normalized.split { $0.isWhitespace || $0.isPunctuation || $0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && stopWords.contains($0) == false }

        var counts: [String: Int] = [:]
        for token in tokens {
            counts[token, default: 0] += 1
        }

        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(64)
            .map(\.key)
    }
}
