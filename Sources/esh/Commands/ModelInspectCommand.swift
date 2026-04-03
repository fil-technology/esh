import Foundation
import EshCore

enum ModelInspectCommand {
    static func run(modelID: String, service: ModelService) throws {
        let manifest = try service.inspect(id: modelID)
        print("id: \(manifest.install.id)")
        print("source: \(manifest.install.spec.source.reference)")
        print("backend: \(manifest.install.spec.backend.rawValue)")
        print("format: \(manifest.install.backendFormat)")
        print("path: \(manifest.install.installPath)")
        print("files: \(manifest.files.count)")
        print("size: \(ByteFormatting.string(for: manifest.install.sizeBytes))")
    }
}
