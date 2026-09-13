import Foundation
import Testing
@testable import EshCore

// M10 #10 — model-store schema versioning + migration/recovery.
@Suite
struct ModelManifestSchemaTests {

    private func sampleManifest() -> ModelManifest {
        let spec = ModelSpec(id: "m1", displayName: "M1", backend: .gguf,
                             source: ModelSource(kind: .localPath, reference: "m1"))
        let install = ModelInstall(id: "m1", spec: spec, installPath: "/tmp/m1/model.gguf",
                                   sizeBytes: 123, backendFormat: "gguf", runtimeVersion: "llama.cpp-embedded")
        return ModelManifest(install: install, files: ["model.gguf"])
    }

    @Test func writeStampsCurrentSchemaVersion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // Even if a caller hands in a stale version, write persists the current one.
        var m = sampleManifest(); m.schemaVersion = 0
        try ModelManifestIO().write(m, to: url)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["schemaVersion"] as? Int == ModelManifest.currentSchemaVersion)
    }

    @Test func legacyManifestWithoutVersionDecodesAsV1() throws {
        // Simulate a pre-versioning file: encode, then strip the schemaVersion key.
        var dict = try JSONSerialization.jsonObject(
            with: JSONCoding.encoder.encode(sampleManifest())) as! [String: Any]
        dict.removeValue(forKey: "schemaVersion")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONCoding.decoder.decode(ModelManifest.self, from: legacy)
        #expect(decoded.schemaVersion == 1)        // legacy → v1, not a decode failure
        #expect(decoded.install.id == "m1")
    }

    @Test func readMigratesLegacyToCurrent() throws {
        var dict = try JSONSerialization.jsonObject(
            with: JSONCoding.encoder.encode(sampleManifest())) as! [String: Any]
        dict.removeValue(forKey: "schemaVersion")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: dict).write(to: url)
        let m = try ModelManifestIO().read(from: url)
        #expect(m.schemaVersion == ModelManifest.currentSchemaVersion)
        #expect(m.install.id == "m1")
    }

    @Test func futureSchemaVersionIsRefused() throws {
        // A record written by a newer app must NOT be silently misread.
        var future = sampleManifest(); future.schemaVersion = ModelManifest.currentSchemaVersion + 5
        #expect(throws: StoreError.self) { _ = try ModelManifestIO.migrate(future) }
    }

    @Test func currentVersionRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let io = ModelManifestIO()
        try io.write(sampleManifest(), to: url)
        let back = try io.read(from: url)
        #expect(back.schemaVersion == ModelManifest.currentSchemaVersion)
        #expect(back.files == ["model.gguf"])
        #expect(back.install.sizeBytes == 123)
    }
}
