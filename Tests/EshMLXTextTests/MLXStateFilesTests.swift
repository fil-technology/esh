import Foundation
import Testing
@testable import EshMLXText

@Suite struct MLXStateFilesTests {
    @Test func stateFilesAreOwnerTaggedInTheDedicatedDirectory() {
        let url = MLXStateFiles.newStateFileURL()
        #expect(url.deletingLastPathComponent().lastPathComponent == "esh-mlx-state")
        #expect(url.lastPathComponent.hasPrefix("\(getpid())-"))
    }

    @Test func removeDeletesTheStateFileAndItsSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-state-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("123-abc.json")
        for name in ["123-abc.json", "123-abc.json.f00.kv.safetensors", "123-abcd.json", "999-x.json"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        MLXStateFiles.remove(state)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["123-abcd.json", "999-x.json"])
    }

    @Test func sweepRemovesOnlyDeadOwners() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-state-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["11-dead.json", "11-dead.json.a.kv.safetensors", "22-live.json", "\(getpid())-mine.json", "readme"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        let removed = MLXStateFiles.sweepStale(in: dir, isAlive: { $0 == 22 })
        #expect(Set(removed) == ["11-dead.json", "11-dead.json.a.kv.safetensors"])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["22-live.json", "\(getpid())-mine.json", "readme"])
    }
}
