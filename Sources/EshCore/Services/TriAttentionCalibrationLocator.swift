import Foundation

public struct TriAttentionCalibrationLocator: Sendable {
    private let root: PersistenceRoot

    public init(root: PersistenceRoot = .default()) {
        self.root = root
    }

    public func calibrationURL(for modelID: String) -> URL {
        root.rootURL
            .appendingPathComponent("compression", isDirectory: true)
            .appendingPathComponent(sanitize(modelID), isDirectory: true)
            .appendingPathComponent("triattention", isDirectory: true)
            .appendingPathComponent("triattention_calib.safetensors")
    }

    public func ensureDirectory(for modelID: String) throws -> URL {
        let fileURL = calibrationURL(for: modelID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return fileURL
    }

    public func hasCalibration(for modelID: String) -> Bool {
        FileManager.default.fileExists(atPath: calibrationURL(for: modelID).path)
    }

    private func sanitize(_ value: String) -> String {
        value.map { character in
            switch character {
            case "/", ":", "?", "&", "=", "\\", " ":
                "_"
            default:
                character
            }
        }.reduce(into: "") { partialResult, character in
            partialResult.append(character)
        }
    }
}
