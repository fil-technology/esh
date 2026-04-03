import Foundation

public struct ModelManifestIO: Sendable {
    public init() {}

    public func write(_ manifest: ModelManifest, to url: URL) throws {
        let data = try JSONCoding.encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    public func read(from url: URL) throws -> ModelManifest {
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(ModelManifest.self, from: data)
    }
}
