import Foundation
import Network

// esh 2.1 — Voice 2.1 realtime duplex transport (server). A WebSocket endpoint that owns a VoiceSession per
// connection: it ingests binary PCM mic frames, runs the server-side EnergyVAD to find utterance boundaries,
// drives the orchestrator (STT→LLM→TTS + barge-in), and streams typed VoiceEvents (TEXT) + TTS audio (BINARY
// VoiceAudioFrame) back. The browser/simulator are thin clients of this. Session/turn ids isolate turns so a
// cancelled turn's late audio is dropped; disconnect ends the session and reaps the orchestrator.
//
// The session factory is injected, so tests drive the REAL transport with fake STT/LLM/TTS over a loopback
// socket (deterministic, fast), while `esh serve` wires the real adapters.
/// Voice 2.1 Install-and-Resume (spec §3) preflight decision for a starting session. `ready` starts the
/// session; `installRequired` holds at a safe boundary (no session, no turns) and the server emits an
/// `install.required` event carrying the missing component + combined Voice Fit, so the client can install
/// (via the managed-SSD installer) and re-`start` to resume. Pure value → the server stays model-store-agnostic.
public enum VoicePreflightDecision: Sendable, Equatable {
    case ready
    case installRequired(component: String, recommendedRepo: String, voiceFit: String, summary: String)
}

public final class VoiceWebSocketServer: @unchecked Sendable {
    public typealias SessionFactory = @Sendable (VoiceSessionConfig) -> VoiceSessionOrchestrator
    /// Optional gate run on each `start`. Default (nil) = always ready (tests/back-compat). `esh serve`
    /// injects a real preflight that checks installed models + combined Voice Fit.
    public typealias Preflight = @Sendable (VoiceSessionConfig) -> VoicePreflightDecision
    private let listener: NWListener
    private let factory: SessionFactory
    private let preflight: Preflight?
    private let queue = DispatchQueue(label: "esh.voice.ws")
    /// The port actually bound (equals the requested port, or the OS-assigned one when 0 was requested).
    public private(set) var resolvedPort: UInt16 = 0
    /// Active connections MUST be retained — otherwise the accepted NWConnection wrapper is deallocated
    /// immediately and its callbacks (all [weak self]) silently no-op. Removed on teardown.
    private var conns: [ObjectIdentifier: VoiceWSConnection] = [:]

    private func accept(_ conn: NWConnection) {
        let c = VoiceWSConnection(connection: conn, factory: factory, preflight: preflight, queue: queue)
        queue.async { self.conns[ObjectIdentifier(c)] = c }
        c.onClose = { [weak self, weak c] in
            guard let self, let c else { return }
            self.queue.async { self.conns.removeValue(forKey: ObjectIdentifier(c)) }
        }
        c.begin()
    }

    /// `port: 0` binds an ephemeral OS-assigned port (use `startAndWait` to learn it). loopback-only.
    public init(port: UInt16 = 0, preflight: Preflight? = nil, factory: @escaping SessionFactory) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if port == 0 {
            self.listener = try NWListener(using: params)
        } else {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw VoiceWSError.badPort }
            self.listener = try NWListener(using: params, on: nwPort)
        }
        self.factory = factory
        self.preflight = preflight
        self.resolvedPort = port
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.accept(conn)
        }
        listener.start(queue: queue)
    }

    /// Start and wait until the listener is bound; returns the resolved port. Throws on bind failure/timeout.
    public func startAndWait(timeout: Double = 5.0) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let done = Locked(false)
            queue.asyncAfter(deadline: .now() + timeout) {
                if done.swap(true) == false { cont.resume(throwing: VoiceWSError.bindTimeout) }
            }
            listener.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    self.resolvedPort = self.listener.port?.rawValue ?? self.resolvedPort
                    if done.swap(true) == false { cont.resume(returning: self.resolvedPort) }
                case .failed(let e):
                    if done.swap(true) == false { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.accept(conn)
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    public enum VoiceWSError: Error, Sendable { case badPort, bindTimeout }

    /// Tiny thread-safe box for the one-shot readiness guard.
    final class Locked: @unchecked Sendable {
        private let lock = NSLock(); private var v: Bool
        init(_ initial: Bool) { v = initial }
        func swap(_ n: Bool) -> Bool { lock.lock(); defer { lock.unlock() }; let o = v; v = n; return o }
    }
}

/// One accepted connection: HTTP→WebSocket upgrade, then frame pump ↔ VoiceSession.
final class VoiceWSConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let factory: VoiceWebSocketServer.SessionFactory
    private let preflight: VoiceWebSocketServer.Preflight?
    private let queue: DispatchQueue

    private enum Phase { case handshake, open, closed }
    private var phase: Phase = .handshake
    private var inBuffer = Data()

    private var orchestrator: VoiceSessionOrchestrator?
    private var eventPump: Task<Void, Never>?
    private var sessionID = UUID().uuidString
    private var orchState: VoiceSessionState = .idle
    private var cmdChain: Task<Void, Never>?   // serializes orchestrator calls in arrival order (no reorder)

    /// Enqueue an orchestrator command so commands run strictly FIFO (submit must not overtake a barge-in).
    private func enqueue(_ op: @escaping @Sendable (VoiceSessionOrchestrator) async -> Void) {
        guard let orch = orchestrator else { return }
        let prev = cmdChain
        cmdChain = Task { await prev?.value; await op(orch) }
    }

    // Server VAD over the incoming PCM stream.
    private var vad = EnergyVADEndpointer(sampleRate: 16000)
    private var vadState = EnergyVADEndpointer.State()
    private var sampleRate = 16000
    private var frameBytes = 640            // 20 ms @ 16 kHz mono PCM16
    private var pcmFrameAccum = Data()      // bytes toward the next VAD frame
    private var utterance = Data()          // PCM for the current utterance (speech → endpoint)
    private var inSpeech = false
    private var turn: UInt32 = 0
    private var audioSeq: UInt32 = 0
    private var levelTick: UInt32 = 0  // throttles input.level emission during speech
    private let echoGuardScale = 3.0   // during playback, require ~3× the base energy to count as barge-in
    var onClose: (@Sendable () -> Void)?

    init(connection: NWConnection, factory: @escaping VoiceWebSocketServer.SessionFactory,
         preflight: VoiceWebSocketServer.Preflight?, queue: DispatchQueue) {
        self.connection = connection; self.factory = factory; self.preflight = preflight; self.queue = queue
    }

    private func dbg(_ s: String) {
        if ProcessInfo.processInfo.environment["ESH_WS_DEBUG"] == "1" { FileHandle.standardError.write(Data("WSSERVER \(s)\n".utf8)) }
    }

    func begin() {
        dbg("accept begin")
        connection.stateUpdateHandler = { [weak self] st in
            self?.dbg("state=\(st)")
            if case .failed = st { self?.teardown() }
            if case .cancelled = st { self?.teardown() }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.dbg("recv \(data.count)B phase=\(self.phase)")
                self.inBuffer.append(data)
                self.pump()
            }
            if isComplete || error != nil { self.teardown(); return }
            if self.phase != .closed { self.receive() }
        }
    }

    private func pump() {
        if phase == .handshake { tryHandshake(); return }
        while phase == .open {
            guard let (frame, consumed) = ((try? WebSocketCodec.decode(inBuffer)) ?? nil) else {
                // nil = incomplete; a thrown error (malformed/oversize) → close.
                if (try? WebSocketCodec.decode(inBuffer)) == nil, !inBuffer.isEmpty, isDefinitelyBadFrame() { close() }
                return
            }
            inBuffer.removeFirst(consumed)
            handle(frame)
        }
    }

    /// Distinguish "incomplete" (wait) from "malformed" (close): decode throws on malformed/oversize.
    private func isDefinitelyBadFrame() -> Bool {
        do { _ = try WebSocketCodec.decode(inBuffer); return false } catch { return true }
    }

    private func tryHandshake() {
        guard let range = inBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }   // headers incomplete
        let headerData = inBuffer.subdata(in: inBuffer.startIndex..<range.lowerBound)
        inBuffer.removeSubrange(inBuffer.startIndex..<range.upperBound)
        let header = String(decoding: headerData, as: UTF8.self)
        let lower = header.lowercased()
        guard lower.contains("upgrade: websocket"),
              let key = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") })?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) else {
            sendRaw(Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8)); close(); return
        }
        let accept = WebSocketCodec.acceptKey(key)
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        dbg("sending 101")
        sendRaw(Data(resp.utf8))
        phase = .open
        if !inBuffer.isEmpty { pump() }
    }

    private func handle(_ frame: WSFrame) {
        switch frame.opcode {
        case .text: handleControl(frame.payload)
        case .binary: handleAudio(frame.payload)
        case .ping: sendFrame(WSFrame(opcode: .pong, payload: frame.payload))
        case .close: close()
        case .pong, .continuation: break
        }
    }

    private func handleControl(_ data: Data) {
        guard let ctrl = VoiceWire.decodeControl(data) else { return }
        switch ctrl.t {
        case "start":
            sampleRate = ctrl.sampleRate ?? 16000
            frameBytes = max(160, (sampleRate / 50) * 2)
            vad = EnergyVADEndpointer(sampleRate: sampleRate)
            vadState = EnergyVADEndpointer.State()
            let cfg = VoiceSessionConfig(language: ctrl.language, sttModel: ctrl.sttModel,
                                         inferenceModel: ctrl.inferenceModel, ttsModel: ctrl.ttsModel)
            // Install-and-Resume preflight (spec §3): if a required voice component is missing, hold at a safe
            // boundary — emit install.required with the combined Voice Fit, start NO session, run NO turns. The
            // client installs via the managed-SSD installer and re-sends `start` to resume.
            if let decision = preflight?(cfg), case let .installRequired(component, repo, fit, summary) = decision {
                sendInstallRequired(component: component, repo: repo, voiceFit: fit, summary: summary)
                return
            }
            startSession(cfg)
        case "reset":
            enqueue { await $0.resetContext() }
            resetUtterance()
        case "interrupt":
            enqueue { await $0.inputSpeechStarted() }   // explicit barge-in
        case "end":
            close()
        default: break
        }
    }

    private func startSession(_ cfg: VoiceSessionConfig) {
        eventPump?.cancel()
        let orch = factory(cfg)
        orchestrator = orch
        sessionID = orch.id
        eventPump = Task { [weak self] in
            for await ev in orch.events { self?.queue.async { self?.emit(ev) } }
        }
        orchState = .idle
        enqueue { await $0.start() }
    }

    private func handleAudio(_ pcm: Data) {
        guard orchestrator != nil else { return }
        pcmFrameAccum.append(pcm)
        while pcmFrameAccum.count >= frameBytes {
            let frame = pcmFrameAccum.prefix(frameBytes)
            pcmFrameAccum.removeFirst(frameBytes)
            let floats = EnergyVADEndpointer.pcm16ToFloat(Data(frame))
            // Echo/self-trigger guard: while the assistant is speaking, raise the VAD bar (playback-reference
            // aware) so its own audio bleeding into the mic doesn't self-interrupt, while louder genuine user
            // speech still barges in. The VAD is NOT disabled during playback (spec §8).
            let scale = (orchState == .speaking) ? echoGuardScale : 1.0
            for sig in vad.process(frame: floats, state: &vadState, thresholdScale: scale) {
                switch sig {
                case .level(let l):
                    // Live input meter so the UI shows it is hearing the mic (throttled ~10/s). Only while the
                    // user is actually speaking, to avoid a jittery idle meter.
                    if inSpeech {
                        levelTick &+= 1
                        if levelTick % 5 == 0 { emit(.inputLevel(l)) }
                    }
                case .speechStarted:
                    inSpeech = true
                    utterance = Data(frame)   // include the onset frame
                    // Tell the client immediately so it can show a live "listening / you are speaking" state —
                    // without this the UI looks frozen until the endpoint. (Emitted for every onset, not just
                    // barge-in.)
                    emit(.vadSpeechStarted)
                    // Only signal the orchestrator when this onset is a BARGE-IN (assistant mid-turn); a normal
                    // listening onset needs no call — the turn is driven by submitUtterance at the endpoint.
                    if orchState == .thinking || orchState == .speaking || orchState == .transcribing {
                        enqueue { await $0.inputSpeechStarted() }
                    }
                case .speechEnded:
                    inSpeech = false
                    emit(.vadSpeechEnded)   // client shows "transcribing…" while STT runs
                    let wav = Self.wrapPCM16(utterance, sampleRate: sampleRate)
                    utterance = Data()
                    turn &+= 1; audioSeq = 0
                    let sr = sampleRate
                    enqueue { await $0.submitUtterance(VoiceAudioInput(bytes: wav, format: "wav", sampleRate: sr)) }
                }
            }
            if inSpeech { utterance.append(frame) }
        }
    }

    private func emit(_ ev: VoiceEvent) {
        if case .stateChanged(let s) = ev { orchState = s }
        switch ev {
        case .ttsAudioChunk(let chunk):
            audioSeq &+= 1
            let af = VoiceAudioFrame(turn: turn, seq: audioSeq, sampleRate: UInt32(chunk.sampleRate),
                                     channels: 1, isFinal: chunk.isFinal, payload: chunk.bytes)
            sendFrame(WSFrame(opcode: .binary, payload: af.encode()))
        default:
            if let json = VoiceWire.encodeEvent(ev, turn: Int(turn), session: sessionID) {
                sendFrame(WSFrame(opcode: .text, payload: json))
            }
        }
    }

    private func resetUtterance() { pcmFrameAccum.removeAll(); utterance.removeAll(); inSpeech = false; vadState = EnergyVADEndpointer.State() }

    /// Install-and-Resume: emit a typed `install.required` event (a TEXT frame) instead of starting a session
    /// with a missing component. Reuses the flat envelope — `message` = human summary, `reason` = combined
    /// Voice Fit, `text` = recommended repo, `state` = component — so no wire schema change is needed.
    private func sendInstallRequired(component: String, repo: String, voiceFit: String, summary: String) {
        var env = VoiceEventEnvelope(t: "install.required")
        env.session = sessionID
        env.state = component
        env.text = repo
        env.message = summary
        env.reason = voiceFit
        if let json = try? JSONEncoder().encode(env) {
            sendFrame(WSFrame(opcode: .text, payload: json))
        }
    }

    private func sendFrame(_ frame: WSFrame) { sendRaw(WebSocketCodec.encode(frame, mask: false)) }
    private func sendRaw(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] err in if err != nil { self?.teardown() } })
    }

    private func close() {
        if phase == .open { sendFrame(WSFrame(opcode: .close)) }
        teardown()
    }

    private func teardown() {
        if phase == .closed { return }
        phase = .closed
        eventPump?.cancel()
        let orch = orchestrator
        Task { await orch?.end(reason: "transport_closed") }
        orchestrator = nil
        connection.cancel()
        onClose?()   // let the server drop its retained reference
    }

    /// Wrap raw PCM16LE mono into a minimal WAV container for the whole-file STT backend.
    static func wrapPCM16(_ pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8*UInt32(i))) & 0xFF)) } }
        func u16(_ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        let dataLen = UInt32(pcm.count)
        str("RIFF"); u32(36 + dataLen); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        str("data"); u32(dataLen); d.append(pcm)
        return d
    }
}
