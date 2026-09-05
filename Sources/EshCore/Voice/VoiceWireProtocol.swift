import Foundation

// esh 2.1 — Voice 2.1 realtime wire protocol. The transport carries two kinds of WebSocket frame:
//   • TEXT  = JSON control (client→server) and JSON VoiceEvents (server→client)
//   • BINARY = audio — raw PCM16LE mic chunks (client→server) and framed TTS audio (server→client)
// This keeps the canonical VoiceEvent model (VoiceEvent.swift) independent of the wire encoding, and never
// base64-wraps realtime audio. Pure + unit-tested; no I/O.

/// Client→server control message (a TEXT frame). Audio arrives as separate BINARY frames.
public struct VoiceControl: Codable, Sendable, Equatable {
    public var t: String                 // "start" | "reset" | "end" | "interrupt"
    public var session: String?
    public var language: String?
    public var sttModel: String?
    public var inferenceModel: String?
    public var ttsModel: String?
    public var sampleRate: Int?          // mic PCM sample rate (default 16000)
    public init(t: String, session: String? = nil, language: String? = nil, sttModel: String? = nil,
                inferenceModel: String? = nil, ttsModel: String? = nil, sampleRate: Int? = nil) {
        self.t = t; self.session = session; self.language = language; self.sttModel = sttModel
        self.inferenceModel = inferenceModel; self.ttsModel = ttsModel; self.sampleRate = sampleRate
    }
}

/// Server→client event (a TEXT frame). One flat envelope carrying whichever fields the event needs; `t` is the
/// canonical dotted VoiceEvent name so the client renders state from a single vocabulary.
public struct VoiceEventEnvelope: Codable, Sendable, Equatable {
    public var t: String
    public var text: String?
    public var state: String?
    public var level: Double?
    public var turn: Int?
    public var message: String?
    public var recoverable: Bool?
    public var reason: String?
    public var session: String?
    public init(t: String) { self.t = t }
}

public enum VoiceWire {
    /// Encode a non-audio VoiceEvent as a TEXT-frame JSON payload. Returns nil for `.ttsAudioChunk` (audio is a
    /// BINARY VoiceAudioFrame instead) so the caller routes audio to the binary path.
    public static func encodeEvent(_ event: VoiceEvent, turn: Int, session: String? = nil) -> Data? {
        var env = VoiceEventEnvelope(t: event.name)
        env.turn = turn; env.session = session
        switch event {
        case .sessionStarted(let id): env.session = id
        case .stateChanged(let s): env.state = s.rawValue
        case .inputLevel(let l): env.level = l
        case .transcriptPartial(let s), .transcriptFinal(let s): env.text = s
        case .assistantTextDelta(let s), .assistantTextFinal(let s): env.text = s
        case .sessionError(let m, let r): env.message = m; env.recoverable = r
        case .sessionEnded(let reason): env.reason = reason
        case .ttsAudioChunk: return nil
        case .vadSpeechStarted, .vadSpeechEnded, .assistantThinkingStarted,
             .ttsStarted, .ttsFinished, .interruptionDetected, .playbackCancelled:
            break
        }
        return try? JSONEncoder().encode(env)
    }

    public static func decodeControl(_ data: Data) -> VoiceControl? {
        try? JSONDecoder().decode(VoiceControl.self, from: data)
    }
}

/// Binary TTS audio frame (server→client): a compact header + payload so audio streams as pure binary while
/// still carrying turn/sequence/format for ordered, turn-isolated playback (late frames from a cancelled turn
/// are dropped by the client). Layout (big-endian): magic "eV"(2) · version(1) · turn(4) · seq(4) ·
/// sampleRate(4) · channels(1) · flags(1; bit0 = isFinal) · payload.
public struct VoiceAudioFrame: Sendable, Equatable {
    public static let magic: [UInt8] = [0x65, 0x56]   // "eV"
    public static let version: UInt8 = 1
    public var turn: UInt32
    public var seq: UInt32
    public var sampleRate: UInt32
    public var channels: UInt8
    public var isFinal: Bool
    public var payload: Data

    public init(turn: UInt32, seq: UInt32, sampleRate: UInt32, channels: UInt8 = 1, isFinal: Bool = false, payload: Data) {
        self.turn = turn; self.seq = seq; self.sampleRate = sampleRate
        self.channels = channels; self.isFinal = isFinal; self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(Self.magic)
        out.append(Self.version)
        func be32(_ v: UInt32) { out.append(UInt8((v >> 24) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF)) }
        be32(turn); be32(seq); be32(sampleRate)
        out.append(channels)
        out.append(isFinal ? 0x01 : 0x00)
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) -> VoiceAudioFrame? {
        let b = [UInt8](data)
        guard b.count >= 17, b[0] == magic[0], b[1] == magic[1], b[2] == version else { return nil }
        func be32(_ o: Int) -> UInt32 { (UInt32(b[o]) << 24) | (UInt32(b[o+1]) << 16) | (UInt32(b[o+2]) << 8) | UInt32(b[o+3]) }
        let turn = be32(3), seq = be32(7), sr = be32(11)
        let channels = b[15]; let isFinal = (b[16] & 0x01) != 0
        return VoiceAudioFrame(turn: turn, seq: seq, sampleRate: sr, channels: channels, isFinal: isFinal, payload: Data(b[17...]))
    }
}
