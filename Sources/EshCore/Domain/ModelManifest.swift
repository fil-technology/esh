import Foundation

public struct ModelManifest: Codable, Hashable, Sendable {
    public var install: ModelInstall
    public var files: [String]
    public var createdAt: Date

    public init(install: ModelInstall, files: [String], createdAt: Date = Date()) {
        self.install = install
        self.files = files
        self.createdAt = createdAt
    }
}
