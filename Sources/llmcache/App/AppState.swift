import Foundation
import LLMCacheCore

struct AppState {
    var sessionName: String
    var backendLabel: String
    var modelLabel: String
    var cacheMode: String
    var metrics: Metrics
    var transcript: [String]

    init(
        sessionName: String,
        backendLabel: String = "MLX",
        modelLabel: String = "(none)",
        cacheMode: String = "raw",
        metrics: Metrics = .init(),
        transcript: [String] = []
    ) {
        self.sessionName = sessionName
        self.backendLabel = backendLabel
        self.modelLabel = modelLabel
        self.cacheMode = cacheMode
        self.metrics = metrics
        self.transcript = transcript
    }
}
