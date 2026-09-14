import Foundation

enum MarkdownTerminalRenderer {
    struct StyledLine: Equatable {
        let text: String
        let tint: String?
    }

    static func render(_ text: String, width: Int, defaultTint: String? = nil) -> [StyledLine] {
        let source = text.isEmpty ? "…" : text
        let lines = source.components(separatedBy: "\n")
        var result: [StyledLine] = []
        var index = 0
        var inCodeBlock = false
        var codeLanguage: String?
        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                inCodeBlock.toggle()
                codeLanguage = inCodeBlock ? (language.isEmpty ? nil : language.lowercased()) : nil
                let label = inCodeBlock
                    ? "\(TerminalUIStyle.faint)code\(language.isEmpty ? "" : " \(language)")\(TerminalUIStyle.reset)"
                    : "\(TerminalUIStyle.faint)end code\(TerminalUIStyle.reset)"
                result.append(StyledLine(text: label, tint: defaultTint))
                index += 1
                continue
            }

            if inCodeBlock {
                let content = rawLine.isEmpty ? " " : rawLine
                let highlighted = highlightCode(content, language: codeLanguage)
                for wrapped in wrapStyled("\(TerminalUIStyle.blue)` \(TerminalUIStyle.reset)\(highlighted)\(TerminalUIStyle.reset)", width: width) {
                    result.append(StyledLine(text: wrapped, tint: defaultTint))
                }
                index += 1
                continue
            }

            if trimmed.isEmpty {
                result.append(StyledLine(text: "", tint: defaultTint))
                index += 1
                continue
            }

            if let heading = headingLine(from: trimmed) {
                for wrapped in wrapStyled(heading, width: width) {
                    result.append(StyledLine(text: wrapped, tint: defaultTint))
                }
                index += 1
                continue
            }

            if let bullet = bulletLine(from: trimmed) {
                for wrapped in wrapStyled(bullet.firstLine, width: width) {
                    result.append(StyledLine(text: wrapped, tint: defaultTint))
                }
                for extra in bullet.remainingLines {
                    for wrapped in wrapStyled(extra, width: width) {
                        result.append(StyledLine(text: wrapped, tint: defaultTint))
                    }
                }
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                let quoteContent = trimmed.drop(while: { $0 == ">" || $0 == " " })
                let rendered = "\(TerminalUIStyle.amber)▌\(TerminalUIStyle.reset) \(renderInline(String(quoteContent)))"
                for wrapped in wrapStyled(rendered, width: width) {
                    result.append(StyledLine(text: wrapped, tint: defaultTint))
                }
                index += 1
                continue
            }

            for wrapped in wrapStyled(renderInline(trimmed), width: width) {
                result.append(StyledLine(text: wrapped, tint: defaultTint))
            }
            index += 1
        }

        return result
    }

    private static func headingLine(from line: String) -> String? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let remainder = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        return "\(TerminalUIStyle.bold)\(TerminalUIStyle.cyan)\(remainder)\(TerminalUIStyle.reset)"
    }

    private struct BulletRender {
        let firstLine: String
        let remainingLines: [String]
    }

    private static func bulletLine(from line: String) -> BulletRender? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            let content = String(line.dropFirst(2))
            return BulletRender(
                firstLine: "\(TerminalUIStyle.blue)•\(TerminalUIStyle.reset) \(renderInline(content))",
                remainingLines: []
            )
        }

        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let marker = parts.first, marker.hasSuffix("."),
              marker.dropLast().allSatisfy(\.isNumber) else {
            return nil
        }

        let remainder = parts.count > 1 ? String(parts[1]) : ""
        return BulletRender(
            firstLine: "\(TerminalUIStyle.blue)\(marker)\(TerminalUIStyle.reset) \(renderInline(remainder))",
            remainingLines: []
        )
    }

    private static func renderInline(_ source: String) -> String {
        let withLinks = replacingMatches(
            pattern: #"\[([^\]]+)\]\(([^)]+)\)"#,
            in: source
        ) { match, nsSource in
            guard match.numberOfRanges == 3,
                  let textRange = Range(match.range(at: 1), in: source),
                  let urlRange = Range(match.range(at: 2), in: source) else {
                return nsSource.substring(with: match.range)
            }
            let label = String(source[textRange])
            let url = String(source[urlRange])
            return "\(TerminalUIStyle.bold)\(label)\(TerminalUIStyle.reset) \(TerminalUIStyle.faint)<\(url)>\(TerminalUIStyle.reset)"
        }

        var result = ""
        var index = withLinks.startIndex

        while index < withLinks.endIndex {
            if withLinks[index] == "`",
               let end = withLinks[withLinks.index(after: index)...].firstIndex(of: "`") {
                let code = String(withLinks[withLinks.index(after: index)..<end])
                result += "\(TerminalUIStyle.blue)`\(TerminalUIStyle.reset)\(TerminalUIStyle.ink)\(code)\(TerminalUIStyle.reset)\(TerminalUIStyle.blue)`\(TerminalUIStyle.reset)"
                index = withLinks.index(after: end)
                continue
            }

            if withLinks[index...].hasPrefix("**"),
               let end = withLinks[withLinks.index(index, offsetBy: 2)...].range(of: "**")?.lowerBound {
                let content = String(withLinks[withLinks.index(index, offsetBy: 2)..<end])
                result += "\(TerminalUIStyle.bold)\(content)\(TerminalUIStyle.reset)"
                index = withLinks.index(end, offsetBy: 2)
                continue
            }

            if withLinks[index...].hasPrefix("*"),
               let end = withLinks[withLinks.index(after: index)...].firstIndex(of: "*") {
                let content = String(withLinks[withLinks.index(after: index)..<end])
                result += "\(TerminalUIStyle.violet)\(content)\(TerminalUIStyle.reset)"
                index = withLinks.index(after: end)
                continue
            }

            result.append(withLinks[index])
            index = withLinks.index(after: index)
        }

        return result
    }

    private static func replacingMatches(
        pattern: String,
        in source: String,
        replacement: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }

        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else { return source }

        var result = source
        for match in matches.reversed() {
            let replacementText = replacement(match, nsSource)
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacementText)
            }
        }
        return result
    }

    private static func highlightCode(_ source: String, language: String?) -> String {
        switch language {
        case "swift":
            return highlightSwift(source)
        case "json":
            return highlightJSON(source)
        case "bash", "sh", "zsh", "shell":
            return highlightShell(source)
        case "python", "py":
            return highlightPython(source)
        default:
            return "\(TerminalUIStyle.ink)\(source)\(TerminalUIStyle.reset)"
        }
    }

    private static func highlightSwift(_ source: String) -> String {
        let result = source
        if let commentRange = result.range(of: #"//.*$"#, options: .regularExpression) {
            let comment = String(result[commentRange])
            let prefix = String(result[..<commentRange.lowerBound])
            return highlightKeywordsAndStrings(
                in: prefix,
                keywords: ["let", "var", "func", "if", "else", "guard", "return", "for", "while", "in", "struct", "class", "enum", "switch", "case", "import", "try", "catch", "throw", "async", "await"]
            ) + "\(TerminalUIStyle.green)\(comment)\(TerminalUIStyle.reset)"
        }
        return highlightKeywordsAndStrings(
            in: result,
            keywords: ["let", "var", "func", "if", "else", "guard", "return", "for", "while", "in", "struct", "class", "enum", "switch", "case", "import", "try", "catch", "throw", "async", "await"]
        )
    }

    private static func highlightJSON(_ source: String) -> String {
        highlightKeywordsAndStrings(in: source, keywords: ["true", "false", "null"])
    }

    private static func highlightShell(_ source: String) -> String {
        let result = source
        if let commentRange = result.range(of: #"#.*$"#, options: .regularExpression) {
            let comment = String(result[commentRange])
            let prefix = String(result[..<commentRange.lowerBound])
            return highlightKeywordsAndStrings(
                in: prefix,
                keywords: ["if", "then", "else", "fi", "for", "do", "done", "case", "esac", "function", "while", "in", "export"]
            ) + "\(TerminalUIStyle.green)\(comment)\(TerminalUIStyle.reset)"
        }
        return highlightKeywordsAndStrings(
            in: result,
            keywords: ["if", "then", "else", "fi", "for", "do", "done", "case", "esac", "function", "while", "in", "export"]
        )
    }

    private static func highlightPython(_ source: String) -> String {
        let result = source
        if let commentRange = result.range(of: #"#.*$"#, options: .regularExpression) {
            let comment = String(result[commentRange])
            let prefix = String(result[..<commentRange.lowerBound])
            return highlightKeywordsAndStrings(
                in: prefix,
                keywords: ["def", "class", "if", "elif", "else", "for", "while", "in", "return", "import", "from", "try", "except", "with", "as", "await", "async", "lambda"]
            ) + "\(TerminalUIStyle.green)\(comment)\(TerminalUIStyle.reset)"
        }
        return highlightKeywordsAndStrings(
            in: result,
            keywords: ["def", "class", "if", "elif", "else", "for", "while", "in", "return", "import", "from", "try", "except", "with", "as", "await", "async", "lambda"]
        )
    }

    private static func highlightKeywordsAndStrings(in source: String, keywords: [String]) -> String {
        let stringRanges = ranges(
            matching: #""([^"\\]|\\.)*"|'([^'\\]|\\.)*'"#,
            in: source
        )

        var result = ""
        var cursor = source.startIndex

        for range in stringRanges {
            let prefix = String(source[cursor..<range.lowerBound])
            result += highlightKeywordsAndNumbers(in: prefix, keywords: keywords)
            let literal = String(source[range])
            result += "\(TerminalUIStyle.amber)\(literal)\(TerminalUIStyle.reset)"
            cursor = range.upperBound
        }

        result += highlightKeywordsAndNumbers(in: String(source[cursor...]), keywords: keywords)
        return result
    }

    private static func highlightKeywordsAndNumbers(in source: String, keywords: [String]) -> String {
        var result = ""
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]

            if character.isWhitespace {
                result.append(character)
                index = source.index(after: index)
                continue
            }

            if character.isNumber || (character == "-" && {
                let next = source.index(after: index)
                return next < source.endIndex && source[next].isNumber
            }()) {
                let end = consumeNumber(in: source, from: index)
                result += "\(TerminalUIStyle.blue)\(source[index..<end])\(TerminalUIStyle.reset)"
                index = end
                continue
            }

            if character.isLetter || character == "_" {
                let end = consumeIdentifier(in: source, from: index)
                let token = String(source[index..<end])
                if keywords.contains(token) {
                    result += "\(TerminalUIStyle.violet)\(token)\(TerminalUIStyle.reset)"
                } else {
                    result += "\(TerminalUIStyle.ink)\(token)\(TerminalUIStyle.reset)"
                }
                index = end
                continue
            }

            result += "\(TerminalUIStyle.ink)\(character)\(TerminalUIStyle.reset)"
            index = source.index(after: index)
        }

        return result
    }

    private static func ranges(matching pattern: String, in source: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
        return matches.compactMap { Range($0.range, in: source) }
    }

    private static func consumeIdentifier(in source: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < source.endIndex, source[cursor].isLetter || source[cursor].isNumber || source[cursor] == "_" {
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    private static func consumeNumber(in source: String, from index: String.Index) -> String.Index {
        var cursor = index
        if source[cursor] == "-" {
            cursor = source.index(after: cursor)
        }
        while cursor < source.endIndex, source[cursor].isNumber || source[cursor] == "." {
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    private static func wrapStyled(_ text: String, width: Int) -> [String] {
        guard !text.isEmpty else { return [""] }

        var result: [String] = []
        var current = ""

        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let token = String(word)
            let tokenWidth = TerminalUIStyle.visibleWidth(of: token)

            if current.isEmpty {
                current = token
            } else if TerminalUIStyle.visibleWidth(of: current) + 1 + tokenWidth <= width {
                current += " " + token
            } else {
                result.append(current)
                current = token
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }
}
