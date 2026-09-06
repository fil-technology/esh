import Foundation
import CryptoKit

// esh 2.1 — Voice 2.1 realtime transport: RFC 6455 WebSocket framing (pure, testable, no I/O). The duplex
// Voice transport uses TEXT frames for JSON control/events and BINARY frames for audio (PCM mic in, TTS out),
// so the opcode itself disambiguates control from audio — no base64 of realtime audio. This file is only the
// codec + handshake math; the server (VoiceWebSocketServer) drives NWConnection with it.

public enum WSOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

public struct WSFrame: Sendable, Equatable {
    public var fin: Bool
    public var opcode: WSOpcode
    public var payload: Data
    public init(fin: Bool = true, opcode: WSOpcode, payload: Data = Data()) {
        self.fin = fin; self.opcode = opcode; self.payload = payload
    }
}

public enum WebSocketCodec {
    /// RFC 6455 §1.3 handshake: base64(SHA1(Sec-WebSocket-Key + magic GUID)).
    public static func acceptKey(_ secWebSocketKey: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((secWebSocketKey + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    /// Serialize one frame. `mask` true for client→server (RFC requires client frames masked); the server
    /// sends unmasked. A random masking key is used when masking.
    public static func encode(_ frame: WSFrame, mask: Bool) -> Data {
        var out = Data()
        out.append((frame.fin ? 0x80 : 0x00) | frame.opcode.rawValue)
        let len = frame.payload.count
        let maskBit: UInt8 = mask ? 0x80 : 0x00
        if len < 126 {
            out.append(maskBit | UInt8(len))
        } else if len <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((len >> shift) & 0xFF)) }
        }
        if mask {
            var key = [UInt8](repeating: 0, count: 4)
            for i in 0..<4 { key[i] = UInt8.random(in: 0...255) }
            out.append(contentsOf: key)
            var masked = [UInt8](frame.payload)
            for i in 0..<masked.count { masked[i] ^= key[i % 4] }
            out.append(contentsOf: masked)
        } else {
            out.append(frame.payload)
        }
        return out
    }

    /// Parse one frame from the FRONT of `buffer`. Returns the frame + bytes consumed, or nil if the buffer
    /// does not yet hold a complete frame (caller accumulates more). Throws on a malformed frame.
    public static func decode(_ buffer: Data) throws -> (frame: WSFrame, consumed: Int)? {
        let b = [UInt8](buffer)
        guard b.count >= 2 else { return nil }
        let fin = (b[0] & 0x80) != 0
        guard let opcode = WSOpcode(rawValue: b[0] & 0x0F) else { throw WSError.badOpcode(b[0] & 0x0F) }
        let masked = (b[1] & 0x80) != 0
        var len = Int(b[1] & 0x7F)
        var idx = 2
        if len == 126 {
            guard b.count >= idx + 2 else { return nil }
            len = (Int(b[idx]) << 8) | Int(b[idx + 1]); idx += 2
        } else if len == 127 {
            guard b.count >= idx + 8 else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(b[idx + i]) }   // UInt64 avoids Int overflow → negative len
            guard v <= UInt64(maxFrameBytes) else { throw WSError.tooLarge(Int(clamping: v)) }
            len = Int(v); idx += 8
        }
        guard len >= 0, len <= maxFrameBytes else { throw WSError.tooLarge(len) }
        var key: [UInt8] = []
        if masked {
            guard b.count >= idx + 4 else { return nil }
            key = Array(b[idx..<idx + 4]); idx += 4
        }
        guard b.count >= idx + len else { return nil }
        var payload = Array(b[idx..<idx + len])
        if masked { for i in 0..<payload.count { payload[i] ^= key[i % 4] } }
        return (WSFrame(fin: fin, opcode: opcode, payload: Data(payload)), idx + len)
    }

    /// Guard against a hostile/huge declared length (realtime audio chunks are small).
    public static let maxFrameBytes = 16 * 1024 * 1024

    public enum WSError: Error, Sendable, Equatable {
        case badOpcode(UInt8)
        case tooLarge(Int)
    }
}
