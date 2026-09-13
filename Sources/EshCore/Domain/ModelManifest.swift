import Foundation

/// On-disk install record for a managed model.
///
/// **Schema versioning (M10).** The persisted record carries an explicit `schemaVersion` so the format can
/// evolve without silently misreading old or newer files:
/// - A file written before versioning existed has no `schemaVersion` key; it decodes as **v1** (the current
///   layout is v1), so legacy installs keep working.
/// - `ModelManifestIO` migrates older versions forward on read and **refuses** a version newer than it
///   understands (a store written by a future app) with a typed error, rather than corrupting it.
/// New fields must be added as optional-with-default and bump `currentSchemaVersion`, with a migration step.
public struct ModelManifest: Codable, Hashable, Sendable {
    /// The newest manifest schema this build writes and can read.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var install: ModelInstall
    public var files: [String]
    public var createdAt: Date

    public init(install: ModelInstall, files: [String], createdAt: Date = Date(),
                schemaVersion: Int = ModelManifest.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.install = install
        self.files = files
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, install, files, createdAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy manifests predate versioning → treat as v1 (the layout they were written with).
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.install = try c.decode(ModelInstall.self, forKey: .install)
        self.files = try c.decode([String].self, forKey: .files)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}
