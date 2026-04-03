import Foundation

public struct PersistenceRoot: Sendable {
    public let rootURL: URL
    public let sessionsURL: URL
    public let cachesURL: URL
    public let modelsURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        self.cachesURL = rootURL.appendingPathComponent("caches", isDirectory: true)
        self.modelsURL = rootURL.appendingPathComponent("models", isDirectory: true)
    }

    public static func `default`() -> PersistenceRoot {
        if let override = ProcessInfo.processInfo.environment["LLMCACHE_HOME"],
           !override.isEmpty {
            return PersistenceRoot(rootURL: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".llmcache", isDirectory: true)
        return PersistenceRoot(rootURL: base)
    }
}
