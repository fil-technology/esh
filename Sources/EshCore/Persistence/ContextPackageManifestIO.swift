import Foundation

public struct ContextPackageManifestIO: Sendable {
    public init() {}

    public func write(_ package: ContextPackage, to url: URL) throws {
        let data = try JSONCoding.encoder.encode(package)
        try data.write(to: url, options: .atomic)
    }

    public func read(from url: URL) throws -> ContextPackage {
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(ContextPackage.self, from: data)
    }
}
