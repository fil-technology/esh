public enum CacheMode: String, Codable, Sendable, CaseIterable {
    case raw
    case turbo
    case triattention
    case automatic = "auto"
}
