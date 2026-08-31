import Foundation

/// Reads and writes the storage configuration that decides where large AI assets live.
///
/// The config file (`storage.json`) always lives on the **internal state root** so it is readable
/// even when the external assets volume is disconnected. The assets root additionally carries a
/// marker file (`.esh-storage.json`) whose id is matched against `assetsVolumeID` to prove the
/// expected volume is really mounted there.
public struct StorageConfigStore: Sendable {
    public static let configFileName = "storage.json"
    public static let markerFileName = ".esh-storage.json"

    /// Internal state root where `storage.json` lives (never relocated).
    public let stateRootURL: URL

    public init(stateRootURL: URL) {
        self.stateRootURL = stateRootURL
    }

    public var configURL: URL {
        stateRootURL.appendingPathComponent(Self.configFileName, isDirectory: false)
    }

    // MARK: - Config file (internal)

    public func load() -> StorageConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONCoding.decoder.decode(StorageConfig.self, from: data) else {
            return .internal
        }
        return config
    }

    public func save(_ config: StorageConfig) throws {
        try FileManager.default.createDirectory(at: stateRootURL, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
    }

    // MARK: - Marker file (assets root)

    public static func markerURL(inAssetsRoot assetsRoot: URL) -> URL {
        assetsRoot.appendingPathComponent(markerFileName, isDirectory: false)
    }

    public func readMarker(inAssetsRoot assetsRoot: URL) -> StorageMarker? {
        let url = Self.markerURL(inAssetsRoot: assetsRoot)
        guard let data = try? Data(contentsOf: url),
              let marker = try? JSONCoding.decoder.decode(StorageMarker.self, from: data) else {
            return nil
        }
        return marker
    }

    @discardableResult
    public func writeMarker(inAssetsRoot assetsRoot: URL, label: String? = nil) throws -> StorageMarker {
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        // Preserve an existing marker id (so rebinding the same volume keeps its identity).
        if let existing = readMarker(inAssetsRoot: assetsRoot) {
            return existing
        }
        let marker = StorageMarker(label: label)
        let data = try JSONCoding.encoder.encode(marker)
        try data.write(to: Self.markerURL(inAssetsRoot: assetsRoot), options: .atomic)
        return marker
    }
}
