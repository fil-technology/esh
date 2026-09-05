import Foundation
import Network

// esh 2.1 — Voice 2.1 realtime WebSocket client + headless simulator. The simulator drives the SAME server
// endpoint the browser will use (never the orchestrator directly), so transport, framing, VAD-on-stream,
// barge-in, and disconnect are exercised end-to-end. Client frames are masked per RFC 6455.

public enum VoiceClientMessage: Sendable {
    case event(VoiceEventEnvelope)
    case audio(VoiceAudioFrame)
    case closed
}

public final class VoiceWebSocketClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "esh.voice.wsclient")
    private var inBuffer = Data()
    private var open = false
    private let host: String
    private let port: UInt16

    private let (stream, continuation) = AsyncStream<VoiceClientMessage>.makeStream(bufferingPolicy: .unbounded)
    public var messages: AsyncStream<VoiceClientMessage> { stream }

    public init(host: String = "127.0.0.1", port: UInt16) {
        self.host = host; self.port = port
        self.connection = NWConnection(host: NWEndpoint.Host(host),
                                       port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    private var handshakeDone = false

    /// Connect + perform the WebSocket upgrade; returns once the server replies 101. Self-times-out so a
    /// stalled handshake fails fast instead of hanging.
    public func connect(timeout: Double = 5.0) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish: @Sendable (Error?) -> Void = { [weak self] err in
                guard let self else { return }
                self.queue.async {
                    if self.handshakeDone { return }
                    self.handshakeDone = true
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(NSError(domain: "voice.ws", code: 3, userInfo: [NSLocalizedDescriptionKey: "connect timed out"]))
            }
            connection.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                if ProcessInfo.processInfo.environment["ESH_WS_DEBUG"] == "1" {
                    FileHandle.standardError.write(Data("WSCLIENT state=\(st)\n".utf8))
                }
                switch st {
                case .ready:
                    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                    let req = "GET /v1/voice/stream HTTP/1.1\r\nHost: \(self.host):\(self.port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
                    self.connection.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
                    self.awaitHandshake(finish)
                case .failed(let e): finish(e)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func awaitHandshake(_ finish: @escaping @Sendable (Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.inBuffer.append(data) }
            if let r = self.inBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: self.inBuffer.subdata(in: self.inBuffer.startIndex..<r.lowerBound), as: UTF8.self)
                self.inBuffer.removeSubrange(self.inBuffer.startIndex..<r.upperBound)
                if head.contains("101") { self.open = true; finish(nil); self.readLoop(); if !self.inBuffer.isEmpty { self.drainFrames() } }
                else { finish(NSError(domain: "voice.ws", code: 1, userInfo: [NSLocalizedDescriptionKey: "handshake failed: \(head.prefix(40))"])) }
                return
            }
            if isComplete || error != nil { finish(error ?? NSError(domain: "voice.ws", code: 2)); return }
            self.awaitHandshake(finish)
        }
    }

    private func readLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.inBuffer.append(data); self.drainFrames() }
            if isComplete || error != nil { self.continuation.yield(.closed); self.continuation.finish(); return }
            if self.open { self.readLoop() }
        }
    }

    private func drainFrames() {
        while let (frame, consumed) = ((try? WebSocketCodec.decode(inBuffer)) ?? nil) {
            inBuffer.removeFirst(consumed)
            switch frame.opcode {
            case .text:
                if let env = try? JSONDecoder().decode(VoiceEventEnvelope.self, from: frame.payload) {
                    continuation.yield(.event(env))
                }
            case .binary:
                if let af = VoiceAudioFrame.decode(frame.payload) { continuation.yield(.audio(af)) }
            case .close:
                continuation.yield(.closed); continuation.finish(); open = false
            default: break
            }
        }
    }

    public func sendControl(_ c: VoiceControl) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        send(WSFrame(opcode: .text, payload: data))
    }
    public func sendAudioPCM(_ pcm: Data) { send(WSFrame(opcode: .binary, payload: pcm)) }
    public func close() { send(WSFrame(opcode: .close)); open = false; connection.cancel() }

    private func send(_ frame: WSFrame) {
        connection.send(content: WebSocketCodec.encode(frame, mask: true), completion: .contentProcessed { _ in })
    }
}

/// A reusable headless "microphone client": streams PCM in realtime-sized chunks, can inject silence/speech,
/// interrupt, and disconnect — exercising the same server path as the browser.
public struct VoiceRealtimeSimulator: Sendable {
    public let client: VoiceWebSocketClient
    public let sampleRate: Int
    public init(port: UInt16, sampleRate: Int = 16000) {
        self.client = VoiceWebSocketClient(port: port); self.sampleRate = sampleRate
    }

    /// Stream PCM16 bytes in ~20 ms chunks at (optionally) realtime pace.
    public func streamPCM(_ pcm: Data, realtime: Bool = false) async {
        let chunk = max(160, (sampleRate / 50) * 2)
        var i = pcm.startIndex
        while i < pcm.endIndex {
            let end = pcm.index(i, offsetBy: chunk, limitedBy: pcm.endIndex) ?? pcm.endIndex
            client.sendAudioPCM(pcm.subdata(in: i..<end))
            i = end
            if realtime { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
    }

    /// Silence PCM16 of a given duration (drives the VAD toward an endpoint).
    public func silence(ms: Int) -> Data {
        Data(count: max(0, (sampleRate * ms / 1000) * 2))
    }
}
