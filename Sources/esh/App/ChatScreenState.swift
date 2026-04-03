import Foundation
import EshCore

enum TranscriptRole: String, Sendable {
    case user
    case assistant
    case system

    var title: String {
        switch self {
        case .user:
            return "You"
        case .assistant:
            return "Assistant"
        case .system:
            return "System"
        }
    }
}

struct TranscriptItem: Identifiable, Sendable {
    let id: UUID
    var role: TranscriptRole
    var text: String
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: TranscriptRole,
        text: String,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

struct OverlayPanelState: Sendable {
    var title: String
    var lines: [String]

    init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }
}

struct ChatScreenState: Sendable {
    var sessionName: String
    var backendLabel: String
    var modelLabel: String
    var cacheMode: String
    var metrics: Metrics
    var statusText: String
    var inputText: String
    var transcriptItems: [TranscriptItem]
    var streamingAssistantMessageID: UUID?
    var overlay: OverlayPanelState?
    var autosaveEnabled: Bool

    init(
        sessionName: String,
        backendLabel: String = "MLX",
        modelLabel: String = "(none)",
        cacheMode: String = "raw",
        metrics: Metrics = .init(),
        statusText: String = "ready",
        inputText: String = "",
        transcriptItems: [TranscriptItem] = [],
        streamingAssistantMessageID: UUID? = nil,
        overlay: OverlayPanelState? = nil,
        autosaveEnabled: Bool = false
    ) {
        self.sessionName = sessionName
        self.backendLabel = backendLabel
        self.modelLabel = modelLabel
        self.cacheMode = cacheMode
        self.metrics = metrics
        self.statusText = statusText
        self.inputText = inputText
        self.transcriptItems = transcriptItems
        self.streamingAssistantMessageID = streamingAssistantMessageID
        self.overlay = overlay
        self.autosaveEnabled = autosaveEnabled
    }
}
