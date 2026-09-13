import Foundation

public struct ModelManifestIO: Sendable {
    public init() {}

    public func write(_ manifest: ModelManifest, to url: URL) throws {
        // Always persist at the current schema version so on-disk records stay forward-consistent.
        var stamped = manifest
        stamped.schemaVersion = ModelManifest.currentSchemaVersion
        let data = try JSONCoding.encoder.encode(stamped)
        try data.write(to: url, options: .atomic)
    }

    public func read(from url: URL) throws -> ModelManifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONCoding.decoder.decode(ModelManifest.self, from: data)
        return try Self.migrate(manifest)
    }

    /// Bring a decoded manifest to the current schema (M10). Older versions are migrated forward; a version
    /// newer than this build understands is refused with a typed error so a downgrade never corrupts a store.
    static func migrate(_ manifest: ModelManifest) throws -> ModelManifest {
        if manifest.schemaVersion > ModelManifest.currentSchemaVersion {
            throw StoreError.invalidManifest(
                "model record schema v\(manifest.schemaVersion) is newer than this build supports "
                + "(v\(ModelManifest.currentSchemaVersion)); update the app to read it.")
        }
        var m = manifest
        // Forward migrations run in order. v1 is the current layout, so this is currently identity; each
        // future bump adds a `if m.schemaVersion < N { …transform…; m.schemaVersion = N }` step here.
        m.schemaVersion = ModelManifest.currentSchemaVersion
        return m
    }
}
