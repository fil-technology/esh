import Foundation
import SwiftParser
import SwiftSyntax

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
        case "html":
            return extractHTML(lines: lines, relativePath: relativePath)
        case "css":
            return extractCSS(lines: lines, relativePath: relativePath)
        case "json":
            return extractJSON(lines: lines, relativePath: relativePath)
        case "markdown":
            return extractMarkdown(lines: lines, relativePath: relativePath)
        default:
            return SymbolExtractionResult(imports: [], symbols: [])
        }
    }

    private func extractSwift(lines: [String], relativePath: String) -> SymbolExtractionResult {
        if let parsed = swiftParserExtraction(content: lines.joined(separator: "\n"), relativePath: relativePath) {
            return parsed
        }

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

    private func swiftParserExtraction(content: String, relativePath: String) -> SymbolExtractionResult? {
        let sourceFile = Parser.parse(source: content)
        let visitor = SwiftSymbolVisitor(sourceFile: sourceFile, relativePath: relativePath)
        visitor.walk(sourceFile)
        return SymbolExtractionResult(
            imports: visitor.imports,
            symbols: visitor.symbols
        )
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

    private func extractHTML(lines: [String], relativePath: String) -> SymbolExtractionResult {
        let assetRegex = makeRegex(#"(?:src|href)=["']([^"']+)["']"#)
        let idRegex = makeRegex(#"id=["']([^"']+)["']"#)
        let classRegex = makeRegex(#"class=["']([^"']+)["']"#)
        let headingRegex = makeRegex(#"<(h[1-6])[^>]*>([^<]+)</h[1-6]>"#)
        let titleRegex = makeRegex(#"<title[^>]*>([^<]+)</title>"#)
        var imports: [String] = []
        var symbols: [SymbolNode] = []

        for (index, line) in lines.enumerated() {
            if let match = firstCapture(in: line, regex: assetRegex) {
                imports.append(match)
            }
            if let title = firstCapture(in: line, regex: titleRegex) {
                symbols.append(SymbolNode(name: "title.\(normalizeSymbol(title))", kind: "title", filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
            }
            if let captures = captures(in: line, regex: headingRegex), captures.count >= 2 {
                symbols.append(SymbolNode(name: "\(captures[0]).\(normalizeSymbol(captures[1]))", kind: captures[0], filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
            }
            if let identifier = firstCapture(in: line, regex: idRegex) {
                symbols.append(SymbolNode(name: "#\(identifier)", kind: "id", filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
            }
            if let classList = firstCapture(in: line, regex: classRegex) {
                for name in classList.split(whereSeparator: \.isWhitespace).map(String.init) where name.isEmpty == false {
                    symbols.append(SymbolNode(name: ".\(name)", kind: "class", filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
                }
            }
        }

        return SymbolExtractionResult(imports: unique(imports), symbols: unique(symbols))
    }

    private func extractCSS(lines: [String], relativePath: String) -> SymbolExtractionResult {
        let importRegex = makeRegex(#"@import\s+(?:url\()?["']?([^"')]+)["']?\)?"#)
        let selectorRegex = makeRegex(#"^\s*([^{]+)\{"#)
        var imports: [String] = []
        var symbols: [SymbolNode] = []

        for (index, line) in lines.enumerated() {
            if let match = firstCapture(in: line, regex: importRegex) {
                imports.append(match)
            }
            if let selector = firstCapture(in: line, regex: selectorRegex) {
                let cleaned = selector
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                for item in cleaned {
                    symbols.append(SymbolNode(name: item, kind: "selector", filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
                }
            }
        }

        return SymbolExtractionResult(imports: unique(imports), symbols: unique(symbols))
    }

    private func extractJSON(lines: [String], relativePath: String) -> SymbolExtractionResult {
        let keyRegex = makeRegex(#""([^"]+)"\s*:"#)
        var symbols: [SymbolNode] = []

        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            let matches = keyRegex.matches(in: line, options: [], range: range)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let captureRange = Range(match.range(at: 1), in: line) else {
                    continue
                }
                let key = String(line[captureRange])
                symbols.append(SymbolNode(name: key, kind: "key", filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
            }
        }

        return SymbolExtractionResult(imports: [], symbols: unique(symbols))
    }

    private func extractMarkdown(lines: [String], relativePath: String) -> SymbolExtractionResult {
        let linkRegex = makeRegex(#"\[[^\]]+\]\(([^)]+)\)"#)
        let headingRegex = makeRegex(#"^(#+)\s+(.+)$"#)
        var imports: [String] = []
        var symbols: [SymbolNode] = []

        for (index, line) in lines.enumerated() {
            if let captures = captures(in: line, regex: headingRegex), captures.count >= 2 {
                let level = captures[0].count
                symbols.append(SymbolNode(name: "h\(level).\(normalizeSymbol(captures[1]))", kind: "heading", filePath: relativePath, lineStart: index + 1, lineEnd: index + 1, containerName: nil))
            }
            if let match = firstCapture(in: line, regex: linkRegex) {
                imports.append(match)
            }
        }

        return SymbolExtractionResult(imports: unique(imports), symbols: unique(symbols))
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

    private func normalizeSymbol(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "&amp;", with: "and")
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
            .joined(separator: "-")
    }

    private func unique(_ values: [String]) -> [String] {
        Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    private func unique(_ values: [SymbolNode]) -> [SymbolNode] {
        Array(NSOrderedSet(array: values)) as? [SymbolNode] ?? values
    }
}

private final class SwiftSymbolVisitor: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private let relativePath: String
    private var containerStack: [String] = []

    var imports: [String] = []
    var symbols: [SymbolNode] = []

    init(sourceFile: SourceFileSyntax, relativePath: String) {
        self.converter = SourceLocationConverter(fileName: relativePath, tree: sourceFile)
        self.relativePath = relativePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let path = node.path.map(\.name.text).joined(separator: ".")
        if path.isEmpty == false {
            imports.append(path)
        }
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        recordType(name: node.name.text, kind: "class", startNode: node, endPosition: node.memberBlock.endPositionBeforeTrailingTrivia)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        recordType(name: node.name.text, kind: "struct", startNode: node, endPosition: node.memberBlock.endPositionBeforeTrailingTrivia)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        recordType(name: node.name.text, kind: "enum", startNode: node, endPosition: node.memberBlock.endPositionBeforeTrailingTrivia)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        recordType(name: node.name.text, kind: "protocol", startNode: node, endPosition: node.memberBlock.endPositionBeforeTrailingTrivia)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        recordType(name: node.name.text, kind: "actor", startNode: node, endPosition: node.memberBlock.endPositionBeforeTrailingTrivia)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.trimmedDescription.replacingOccurrences(of: " ", with: "")
        recordSymbol(
            name: name,
            kind: "extension",
            startNode: node,
            endPosition: node.memberBlock.endPositionBeforeTrailingTrivia,
            containerName: containerStack.last
        )
        containerStack.append(name)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        let name = node.extendedType.trimmedDescription.replacingOccurrences(of: " ", with: "")
        popContainer(named: name)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let endPosition = node.body?.endPositionBeforeTrailingTrivia ?? node.signature.endPositionBeforeTrailingTrivia
        recordSymbol(
            name: qualifiedName(for: node.name.text),
            kind: "func",
            startNode: node,
            endPosition: endPosition,
            containerName: containerStack.last
        )
        return .skipChildren
    }

    private func recordType(name: String, kind: String, startNode: some SyntaxProtocol, endPosition: AbsolutePosition) {
        recordSymbol(name: name, kind: kind, startNode: startNode, endPosition: endPosition, containerName: containerStack.last)
        containerStack.append(name)
    }

    private func recordSymbol(
        name: String,
        kind: String,
        startNode: some SyntaxProtocol,
        endPosition: AbsolutePosition,
        containerName: String?
    ) {
        let start = converter.location(for: startNode.positionAfterSkippingLeadingTrivia)
        let end = converter.location(for: endPosition)
        let startLine = start.line
        let endLine = max(end.line, startLine)
        symbols.append(
            SymbolNode(
                name: name,
                kind: kind,
                filePath: relativePath,
                lineStart: startLine,
                lineEnd: endLine,
                containerName: containerName
            )
        )
    }

    private func qualifiedName(for name: String) -> String {
        guard let container = containerStack.last else {
            return name
        }
        return "\(container).\(name)"
    }

    private func popContainer(named name: String) {
        if containerStack.last == name {
            containerStack.removeLast()
        } else if let index = containerStack.lastIndex(of: name) {
            containerStack.remove(at: index)
        }
    }
}
