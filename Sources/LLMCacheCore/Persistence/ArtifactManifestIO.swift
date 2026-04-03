import Foundation

public struct ArtifactManifestIO: Sendable {
    public init() {}

    public func write(_ manifest: CacheArtifact, to url: URL) throws {
        let data = try JSONCoding.encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    public func read(from url: URL) throws -> CacheArtifact {
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(CacheArtifact.self, from: data)
    }
}
