import Foundation

public struct ContextStore: Sendable {
    private let locator: WorkspaceContextLocator

    public init(locator: WorkspaceContextLocator = .init()) {
        self.locator = locator
    }

    public func save(index: ContextIndex, workspaceRootURL: URL) throws {
        try locator.ensureIndexDirectory(for: workspaceRootURL)
        let data = try JSONCoding.encoder.encode(index)
        try data.write(to: locator.indexFileURL(for: workspaceRootURL), options: .atomic)
    }

    public func load(workspaceRootURL: URL) throws -> ContextIndex {
        let url = locator.indexFileURL(for: workspaceRootURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound("No context index found for \(workspaceRootURL.path). Run `esh context build` first.")
        }
        return try JSONCoding.decoder.decode(ContextIndex.self, from: Data(contentsOf: url))
    }

    public func status(workspaceRootURL: URL) throws -> ContextStatus {
        let index = try load(workspaceRootURL: workspaceRootURL)
        return ContextStatus(
            workspaceRootPath: index.workspaceRootPath,
            builtAt: index.builtAt,
            fileCount: index.files.count,
            symbolCount: index.symbols.count,
            edgeCount: index.edges.count
        )
    }
}
