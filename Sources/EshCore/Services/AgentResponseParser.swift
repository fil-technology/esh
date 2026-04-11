import Foundation

public struct AgentResponseParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> AgentParsedResponse? {
        if let final = fencedBlock(named: "final", in: text) {
            return .final(final.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let toolBlock = fencedBlock(named: "tool", in: text) else {
            return nil
        }

        let lines = toolBlock.components(separatedBy: .newlines)
        var name: String?
        var inputLines: [String] = []
        var collectingInput = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                collectingInput = false
            } else if trimmed == "input:" {
                collectingInput = true
            } else if trimmed.hasPrefix("input:") {
                collectingInput = true
                let inline = String(trimmed.dropFirst("input:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if inline.isEmpty == false {
                    inputLines.append(inline)
                }
            } else if collectingInput {
                inputLines.append(line)
            }
        }

        guard let name, name.isEmpty == false else {
            return nil
        }

        return .tool(
            AgentToolCall(
                name: name,
                input: inputLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    private func fencedBlock(named name: String, in text: String) -> String? {
        let pattern = "```" + NSRegularExpression.escapedPattern(for: name) + "\\s*\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsrange),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
