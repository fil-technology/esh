import Foundation
import Testing
@testable import EshCore

@Suite
struct SpeechWorkerTests {
    private func decode(_ json: String) throws -> SpeechWorkerLine {
        try JSONCoding.decoder.decode(SpeechWorkerLine.self, from: Data(json.utf8))
    }

    // M12: the persistent STT worker's stdio protocol must decode ready/result/error lines.
    @Test
    func decodesReadyEvent() throws {
        let line = try decode(#"{"event":"ready","loadMs":1234.5,"memoryBytes":987654321,"model":"parakeet"}"#)
        #expect(line.event == "ready")
        #expect(line.loadMs == 1234.5)
        #expect(line.memoryBytes == 987654321)
        #expect(line.id == nil)
    }

    @Test
    func decodesResultEvent() throws {
        let line = try decode(#"{"id":"abc","event":"result","text":"hello world","ms":42.0}"#)
        #expect(line.id == "abc")
        #expect(line.event == "result")
        #expect(line.text == "hello world")
        #expect(line.ms == 42.0)
    }

    @Test
    func decodesErrorEvent() throws {
        let line = try decode(#"{"id":"abc","event":"error","message":"boom"}"#)
        #expect(line.event == "error")
        #expect(line.message == "boom")
    }

    // A fresh manager reports no resident model until a transcription warms one.
    @Test
    func managerHasNoResidentModelBeforeUse() async {
        let manager = SpeechRuntimeManager(idleTimeout: 0)
        let resident = await manager.residentModel()
        #expect(resident == nil)
    }
}
