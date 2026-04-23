import Foundation
import EshCore

enum CapabilitiesCommand {
    static func run(arguments: [String], root: PersistenceRoot, toolVersion: String?) throws {
        guard arguments.isEmpty else {
            throw StoreError.invalidManifest("Usage: esh capabilities")
        }

        let modelStore = FileModelStore(root: root)
        let response = try ExternalCapabilitiesService(modelStore: modelStore)
            .describe(toolVersion: toolVersion)
        let data = try JSONCoding.encoder.encode(response)
        print(String(decoding: data, as: UTF8.self))
    }
}
