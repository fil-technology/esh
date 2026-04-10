import Foundation

public struct SymbolExtractionResult: Hashable, Sendable {
    public let imports: [String]
    public let symbols: [SymbolNode]

    public init(imports: [String], symbols: [SymbolNode]) {
        self.imports = imports
        self.symbols = symbols
    }
}

public struct SymbolExtractor: Sendable {
    public init() {}

    public func extractSymbols(
        from content: String,
        relativePath: String,
        language: String?
    ) -> SymbolExtractionResult {
        let lines = content.components(separatedBy: .newlines)
        switch language {
        case "swift":
            return extractSwift(lines: lines, relativePath: relativePath)
        case "python":
            return extractPython(lines: lines, relativePath: relativePath)
        case "javascript", "typescript":
            return extractJavaScript(lines: lines, relativePath: relativePath)
        case "rust":
            return extractRust(lines: lines, relativePath: relativePath)
        default:
            return SymbolExtractionResult(imports: [], symbols: [])
        }
    }

    private func extractSwift(lines: [String], relativePath: String) -> SymbolExtractionResult {
        let importRegex = makeRegex(#"^\s*import\s+([A-Za-z_][A-Za-z0-9_\.]*)"#)
        let symbolRegex = makeRegex(#"^\s*(?:public|internal|private|fileprivate|open)?\s*(?:final|indirect)?\s*(actor|class|struct|enum|protocol|extension|func)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        var imports: [String] = []
        var symbols: [SymbolNode] = []
        var containerStack: [(name: String, depth: Int)] = []
        var braceDepth = 0

        for (index, line) in lines.enumerated() {
            if let match = firstCapture(in: line, regex: importRegex) {
                imports.append(match)
            }
            if let captures = captures(in: line, regex: symbolRegex), captures.count >= 2 {
                let kind = captures[0]
                let match = captures[1]
                let container = containerStack.last?.name
                symbols.append(
                    SymbolNode(
                        name: qualifiedName(name: match, container: container, kind: kind),
                        kind: kind,
                        filePath: relativePath,
                        lineStart: index + 1,
                        lineEnd: index + 1,
                        containerName: container
                    )
                )
                if ["class", "struct", "enum", "protocol", "extension", "actor"].contains(kind) {
                    containerStack.append((name: match, depth: braceDepth + openingBraceCount(in: line)))
                }
            }
            braceDepth += openingBraceCount(in: line)
            braceDepth -= closingBraceCount(in: line)
            while let last = containerStack.last, braceDepth < last.depth {
                containerStack.removeLast()
            }
        }

        return SymbolExtractionResult(imports: imports, symbols: symbols)
    }

    private func extractPython(lines: [String], relativePath: String) -> SymbolExtractionResult {
        let importRegex = makeRegex(#"^\s*(?:from\s+([A-Za-z_][A-Za-z0-9_\.]*)\s+import|import\s+([A-Za-z_][A-Za-z0-9_\.]*))"#)
        let classRegex = makeRegex(#"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let funcRegex = makeRegex(#"^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        var imports: [String] = []
        var symbols: [SymbolNode] = []
        var currentClass: String?

        for (index, line) in lines.enumerated() {
            if let capture = firstAvailableCapture(in: line, regex: importRegex) {
                imports.append(capture)
            }
            if leadingWhitespace(in: line) == 0, line.trimmingCharacters(in: .whitespaces).hasPrefix("class") == false {
                currentClass = nil
            }
            if let className = firstCapture(in: line, regex: classRegex) {
                currentClass = className
                symbols.append(SymbolNode(name: className, kind: "class", filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
            } else if let functionName = firstCapture(in: line, regex: funcRegex) {
                symbols.append(
                    SymbolNode(
                        name: qualifiedName(name: functionName, container: currentClass, kind: "func"),
                        kind: "func",
                        filePath: relativePath,
                        lineStart: index + 1,
                        lineEnd: index + 1,
                        containerName: currentClass
                    )
                )
            }
        }

        return SymbolExtractionResult(imports: imports, symbols: symbols)
    }

    private func extractJavaScript(lines: [String], relativePath: String) -> SymbolExtractionResult {
        let importRegex = makeRegex(#"^\s*import\s+.*?from\s+['"]([^'"]+)['"]"#)
        let requireRegex = makeRegex(#"require\(['"]([^'"]+)['"]\)"#)
        let symbolRegex = makeRegex(#"^\s*(?:export\s+)?(?:async\s+)?(?:function|class|const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        var imports: [String] = []
        var symbols: [SymbolNode] = []

        for (index, line) in lines.enumerated() {
            if let match = firstCapture(in: line, regex: importRegex) ?? firstCapture(in: line, regex: requireRegex) {
                imports.append(match)
            }
            if let name = firstCapture(in: line, regex: symbolRegex) {
                symbols.append(SymbolNode(name: name, kind: symbolKind(for: line), filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
            }
        }
        return SymbolExtractionResult(imports: imports, symbols: symbols)
    }

    private func extractRust(lines: [String], relativePath: String) -> SymbolExtractionResult {
        let importRegex = makeRegex(#"^\s*use\s+([^;]+)"#)
        let symbolRegex = makeRegex(#"^\s*(?:pub\s+)?(?:async\s+)?(?:fn|struct|enum|trait|mod|impl)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        var imports: [String] = []
        var symbols: [SymbolNode] = []

        for (index, line) in lines.enumerated() {
            if let match = firstCapture(in: line, regex: importRegex) {
                imports.append(match)
            }
            if let name = firstCapture(in: line, regex: symbolRegex) {
                symbols.append(SymbolNode(name: name, kind: symbolKind(for: line), filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
            }
        }
        return SymbolExtractionResult(imports: imports, symbols: symbols)
    }

    private func symbolKind(for line: String) -> String {
        for keyword in ["actor", "class", "struct", "enum", "protocol", "extension", "func", "trait", "mod", "impl"] {
            if line.contains(keyword) {
                return keyword == "extension" ? "extension" : keyword
            }
        }
        if line.contains("function") {
            return "func"
        }
        if line.contains("const") || line.contains("let") || line.contains("var") {
            return "var"
        }
        return "symbol"
    }

    private func qualifiedName(name: String, container: String?, kind: String) -> String {
        guard let container, kind == "func" else {
            return name
        }
        return "\(container).\(name)"
    }

    private func makeRegex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private func openingBraceCount(in line: String) -> Int {
        line.reduce(into: 0) { count, character in
            if character == "{" {
                count += 1
            }
        }
    }

    private func closingBraceCount(in line: String) -> Int {
        line.reduce(into: 0) { count, character in
            if character == "}" {
                count += 1
            }
        }
    }

    private func leadingWhitespace(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private func firstCapture(in text: String, regex: NSRegularExpression) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private func firstAvailableCapture(in text: String, regex: NSRegularExpression) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            if let captureRange = Range(match.range(at: index), in: text) {
                return String(text[captureRange])
            }
        }
        return nil
    }

    private func captures(in text: String, regex: NSRegularExpression) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        var values: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let captureRange = Range(match.range(at: index), in: text) else {
                continue
            }
            values.append(String(text[captureRange]))
        }
        return values.isEmpty ? nil : values
    }
}
