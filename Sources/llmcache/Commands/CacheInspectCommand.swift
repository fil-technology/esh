import Foundation
import LLMCacheCore

enum CacheInspectCommand {
    static func run(arguments: [String], store: CacheStore) throws {
        guard let subcommand = arguments.first else {
            try list(store: store)
            return
        }

        switch subcommand {
        case "inspect":
            if let rawID = arguments.dropFirst().first {
                guard let id = UUID(uuidString: rawID) else {
                    throw StoreError.invalidManifest("Usage: llmcache cache inspect <artifact-uuid>")
                }
                let (artifact, _) = try store.loadArtifact(id: id)
                CacheInspectorView.render(artifact: artifact)
            } else {
                try list(store: store)
            }
        default:
            throw StoreError.invalidManifest("Unknown cache subcommand: \(subcommand)")
        }
    }

    private static func list(store: CacheStore) throws {
        let artifacts = try store.listArtifacts()
        if artifacts.isEmpty {
            print("No cache artifacts.")
            return
        }
        for artifact in artifacts {
            print("\(artifact.id.uuidString)\t\(artifact.manifest.modelID)\t\(artifact.manifest.cacheMode.rawValue)\t\(ByteFormatting.string(for: artifact.sizeBytes))")
        }
    }
}
