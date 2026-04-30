import Foundation

public struct EshConfigStore {
    public let root: PersistenceRoot
    public let configURL: URL

    public init(root: PersistenceRoot = .default()) {
        self.root = root
        self.configURL = root.rootURL.appendingPathComponent("config.toml")
    }

    @discardableResult
    public func initializeIfNeeded(force: Bool = false) throws -> Bool {
        try FileManager.default.createDirectory(at: root.rootURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: configURL.path), !force {
            return false
        }
        try Data(EshConfig.default.tomlString.utf8).write(to: configURL, options: .atomic)
        return true
    }

    public func load() throws -> EshConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .default
        }
        let text = try String(contentsOf: configURL, encoding: .utf8)
        return try EshConfig(tomlText: text)
    }

    public func displayText() throws -> String {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return EshConfig.default.tomlString
        }
        return try String(contentsOf: configURL, encoding: .utf8)
    }
}
