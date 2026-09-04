import Foundation
import Testing
@testable import EshCore

@Suite
struct WebLibRegistryTests {
    // A temp web-libs cache with one fake lib "faketest" whose file hash we compute, so resolution can be
    // tested without the real 670 KB three.js payload.
    private func fixture() throws -> (cacheRoot: URL, registry: [WebLib], dir: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("esh-weblib-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("faketest/1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data("export const answer = 42;\n".utf8)
        try bytes.write(to: dir.appendingPathComponent("faketest.module.js"))
        let sha = WebLibVendor.sha256Hex(bytes)
        let lib = WebLib(id: "faketest", version: "1.0.0", license: "MIT",
                         files: [.init(filename: "faketest.module.js", sha256: sha, importSpecifier: "faketest")],
                         sourceURL: "https://example.test/faketest.js")
        return (root, [lib], dir)
    }

    @Test func resolvesApprovedVendoredLibIntoImportMapAndBundle() throws {
        let (root, registry, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let r = DependencyResolver(cacheRoot: root, registry: registry).resolve(["faketest"])
        #expect(r.rejected.isEmpty)
        #expect(r.importMap["faketest"] == "./vendor/faketest/faketest.module.js")
        #expect(r.bundleFiles["vendor/faketest/faketest.module.js"] != nil)  // maps to the cache abs path
        #expect(r.resolved.first?.name == "faketest")
        #expect(r.resolved.first?.source == .vendored)
        #expect(r.resolved.first?.integritySHA256 != nil)
    }

    @Test func rejectsUnknownLibrary() throws {
        let (root, registry, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let r = DependencyResolver(cacheRoot: root, registry: registry).resolve(["faketest", "left-pad", "malware-xyz"])
        #expect(r.rejected.sorted() == ["left-pad", "malware-xyz"])
        #expect(r.importMap["faketest"] != nil)          // the approved one still resolves
        #expect(r.importMap["left-pad"] == nil)
    }

    @Test func rejectsApprovedLibWhenNotVendored() {
        // Registry knows "faketest" but the cache is empty → esh does NOT fetch at request time → rejected.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("esh-empty-\(UUID().uuidString)")
        let lib = WebLib(id: "faketest", version: "1.0.0", license: "MIT",
                         files: [.init(filename: "faketest.module.js", sha256: "deadbeef", importSpecifier: "faketest")],
                         sourceURL: "x")
        let r = DependencyResolver(cacheRoot: empty, registry: [lib]).resolve(["faketest"])
        #expect(r.rejected == ["faketest"])
        #expect(r.resolved.isEmpty)
    }

    @Test func integrityMismatchIsRejected() throws {
        let (root, registry, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        // Tamper with the vendored file after it was pinned.
        try Data("export const answer = 999; // tampered\n".utf8).write(to: dir.appendingPathComponent("faketest.module.js"))
        let r = DependencyResolver(cacheRoot: root, registry: registry).resolve(["faketest"])
        #expect(r.rejected == ["faketest"])   // hash no longer matches the pin
    }

    @Test func vendorBytesVerifiesIntegrity() throws {
        let (root, _, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = dir.appendingPathComponent("faketest.module.js").path
        let good = WebLibVendor.sha256Hex(try Data(contentsOf: URL(fileURLWithPath: path)))
        #expect((try? WebLibVendor.bytes(at: path, expectedSHA256: good)) != nil)
        #expect((try? WebLibVendor.bytes(at: path, expectedSHA256: "0000")) == nil)   // mismatch throws
        #expect((try? WebLibVendor.bytes(at: root.appendingPathComponent("nope.js").path, expectedSHA256: nil)) == nil)
    }

    @Test func realRegistryHasThreePinned() {
        let three = WebLibRegistry.entry(for: "three")
        #expect(three != nil)
        #expect(three?.license == "MIT")
        #expect(three?.files.first?.importSpecifier == "three")
        #expect(three?.files.first?.sha256.count == 64)   // a real sha256 hex
    }
}
