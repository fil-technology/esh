import Foundation
import EshCore

enum CacheInspectorView {
    static func render(artifact: CacheArtifact) {
        print("id: \(artifact.id.uuidString)")
        print("backend: \(artifact.manifest.backend.rawValue)")
        print("model: \(artifact.manifest.modelID)")
        print("mode: \(artifact.manifest.cacheMode.rawValue)")
        print("runtime: \(artifact.manifest.runtimeVersion)")
        print("format: \(artifact.manifest.cacheFormatVersion)")
        print("compressor: \(artifact.manifest.compressorVersion ?? "-")")
        print("created: \(artifact.manifest.createdAt)")
        print("size: \(ByteFormatting.string(for: artifact.sizeBytes))")
        if let snapshotSize = artifact.snapshotSizeBytes {
            print("snapshot size: \(ByteFormatting.string(for: snapshotSize))")
        }
    }
}
