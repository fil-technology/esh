import Foundation

public struct RoutingConfigurationStore: Sendable {
    private let fileURL: URL

    public init(root: PersistenceRoot = .default()) {
        self.fileURL = root.rootURL.appendingPathComponent("routing.json")
    }

    public func load() throws -> RoutingConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return RoutingConfiguration()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONCoding.decoder.decode(RoutingConfiguration.self, from: data)
    }

    public func save(_ configuration: RoutingConfiguration) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONCoding.encoder.encode(configuration)
        try data.write(to: fileURL, options: [.atomic])
    }
}
