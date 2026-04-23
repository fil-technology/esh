public enum SessionIntent: String, Codable, Sendable, CaseIterable {
    case chat
    case code
    case documentQA = "documentqa"
    case agentRun = "agentrun"
    case multimodal
}
