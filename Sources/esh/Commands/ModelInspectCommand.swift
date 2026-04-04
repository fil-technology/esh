import Foundation
import EshCore

enum ModelInspectCommand {
    static func run(modelID: String, service: ModelService) throws {
        let resolvedID = try resolveModelID(identifier: modelID, service: service)
        let manifest = try service.inspect(id: resolvedID)
        print("id: \(manifest.install.id)")
        print("source: \(manifest.install.spec.source.reference)")
        print("backend: \(manifest.install.spec.backend.rawValue)")
        print("format: \(manifest.install.backendFormat)")
        if let variant = manifest.install.spec.variant {
            print("variant: \(variant)")
        }
        print("path: \(manifest.install.installPath)")
        print("files: \(manifest.files.count)")
        print("size: \(ByteFormatting.string(for: manifest.install.sizeBytes))")
    }

    static func resolveModelID(identifier: String, service: ModelService) throws -> String {
        let installs = try service.list()
        if let install = CommandSupport.resolveInstall(identifier: identifier, installs: installs) {
            return install.id
        }
        throw StoreError.notFound("Model \(identifier) is not installed.")
    }
}
