public struct CompatibilityIssue: Error, Codable, Hashable, Sendable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public protocol CompatibilityChecking: Sendable {
    func validate(manifest: CacheManifest) throws
}
