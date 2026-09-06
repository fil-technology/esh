import Foundation
import Testing
@testable import EshCore

@Suite
struct VoiceWireTests {
    // MARK: WebSocket framing (RFC 6455)

    @Test
    func handshakeAcceptKeyMatchesRFCExample() {
        // RFC 6455 §1.3 canonical example.
        #expect(WebSocketCodec.acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test
    func frameRoundTripsMaskedAndUnmasked() throws {
        for op in [WSOpcode.text, .binary] {
            let payload = Data((0..<300).map { UInt8($0 & 0xFF) })   // >126 → 16-bit length path
            for mask in [true, false] {
                let enc = WebSocketCodec.encode(WSFrame(opcode: op, payload: payload), mask: mask)
                let dec = try WebSocketCodec.decode(enc)
                #expect(dec != nil)
                #expect(dec!.frame.opcode == op)
                #expect(dec!.frame.payload == payload)
                #expect(dec!.consumed == enc.count)
            }
        }
    }

    @Test
    func decodeReturnsNilOnIncompleteBufferThenParsesWhenComplete() throws {
        let full = WebSocketCodec.encode(WSFrame(opcode: .text, payload: Data("hello".utf8)), mask: true)
        #expect(try WebSocketCodec.decode(full.prefix(3)) == nil)   // header incomplete
        let two = full + WebSocketCodec.encode(WSFrame(opcode: .binary, payload: Data([1,2,3])), mask: true)
        let first = try WebSocketCodec.decode(two)
        #expect(first != nil && first!.frame.opcode == .text)
        let rest = two.suffix(from: two.startIndex.advanced(by: first!.consumed))
        let second = try WebSocketCodec.decode(Data(rest))
        #expect(second != nil && second!.frame.opcode == .binary && second!.frame.payload == Data([1,2,3]))
    }

    @Test
    func decodeRejectsOversizeAndBadOpcode() {
        // Declared 8-byte length way over the cap.
        var hostile = Data([0x82, 127]); for _ in 0..<8 { hostile.append(0xFF) }
        #expect(throws: WebSocketCodec.WSError.self) { _ = try WebSocketCodec.decode(hostile) }
        let badOp = Data([0x83, 0x00])   // opcode 0x3 is reserved/invalid
        #expect(throws: WebSocketCodec.WSError.self) { _ = try WebSocketCodec.decode(badOp) }
    }

    // MARK: Voice control / event JSON

    @Test
    func controlDecodesAndEventEncodes() {
        let ctrl = VoiceWire.decodeControl(Data(#"{"t":"start","session":"s1","language":"en","sampleRate":16000}"#.utf8))
        #expect(ctrl?.t == "start" && ctrl?.session == "s1" && ctrl?.sampleRate == 16000)

        let data = VoiceWire.encodeEvent(.transcriptFinal("hello there"), turn: 2, session: "s1")
        #expect(data != nil)
        let env = try? JSONDecoder().decode(VoiceEventEnvelope.self, from: data!)
        #expect(env?.t == "transcript.final" && env?.text == "hello there" && env?.turn == 2)
        // Audio chunk is NOT a TEXT event — it goes on the binary path.
        #expect(VoiceWire.encodeEvent(.ttsAudioChunk(VoiceAudioChunk(bytes: Data([1]), sampleRate: 24000)), turn: 1) == nil)
    }

    // MARK: Binary audio frame

    @Test
    func audioFrameRoundTripsWithHeader() {
        let pcm = Data((0..<512).map { UInt8($0 & 0xFF) })
        let f = VoiceAudioFrame(turn: 7, seq: 42, sampleRate: 24000, channels: 1, isFinal: true, payload: pcm)
        let dec = VoiceAudioFrame.decode(f.encode())
        #expect(dec != nil)
        #expect(dec!.turn == 7 && dec!.seq == 42 && dec!.sampleRate == 24000 && dec!.isFinal && dec!.payload == pcm)
        // Wrong magic → nil.
        #expect(VoiceAudioFrame.decode(Data([0,0,1])) == nil)
    }
}
