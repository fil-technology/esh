import Foundation

public struct WorkspaceContextLocator: Sendable {
    private let root: PersistenceRoot

    public init(root: PersistenceRoot = .default()) {
        self.root = root
    }

    public func workspaceRootURL(from currentDirectoryURL: URL) -> URL {
        if let gitRoot = gitRootURL(from: currentDirectoryURL) {
            return gitRoot
        }
        return currentDirectoryURL
    }

    public func indexDirectoryURL(for workspaceRootURL: URL) -> URL {
        root.rootURL
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent(Fingerprint.sha256([workspaceRootURL.path]), isDirectory: true)
    }

    public func indexFileURL(for workspaceRootURL: URL) -> URL {
        indexDirectoryURL(for: workspaceRootURL).appendingPathComponent("index.json")
    }

    public func ensureIndexDirectory(for workspaceRootURL: URL) throws {
        try FileManager.default.createDirectory(
            at: indexDirectoryURL(for: workspaceRootURL),
            withIntermediateDirectories: true
        )
    }

    private func gitRootURL(from currentDirectoryURL: URL) -> URL? {
        let output = try? ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "-C", currentDirectoryURL.path, "rev-parse", "--show-toplevel"]
        )
        guard let output, output.exitCode == 0 else {
            return nil
        }
        let path = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
