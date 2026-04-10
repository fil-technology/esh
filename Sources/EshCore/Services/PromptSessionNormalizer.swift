import Foundation

public struct PromptSessionNormalizer: Sendable {
    public init() {}

    public func normalized(session: ChatSession) -> ChatSession {
        var normalizedMessages: [Message] = []
        normalizedMessages.reserveCapacity(session.messages.count)

        for message in session.messages {
            let normalizedText = normalized(text: message.text)
            guard normalizedText.isEmpty == false else { continue }

            var normalizedMessage = message
            normalizedMessage.text = normalizedText
            normalizedMessages.append(normalizedMessage)
        }

        var normalizedSession = session
        normalizedSession.messages = normalizedMessages
        return normalizedSession
    }

    public func normalized(text: String) -> String {
        let unifiedNewlines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let trimmedLines = unifiedNewlines
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            }

        return trimmedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}
