import Foundation

public struct Logger: Sendable {
    public enum Level: String, Sendable {
        case info
        case warning
        case error
    }

    public init() {}

    public func log(_ level: Level, _ message: String) {
        fputs("[\(level.rawValue.uppercased())] \(message)\n", stderr)
    }
}
