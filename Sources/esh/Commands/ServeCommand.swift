import Foundation
import Darwin
import EshCore

enum ServeCommand {
    static let defaultPort: UInt16 = 11435
    private static let usage = "Usage: esh serve [--host 127.0.0.1|localhost|::1|0.0.0.0|::] [--port <1-65535>] [--api-key <token>]"

    static func run(arguments: [String], root: PersistenceRoot, toolVersion: String?) async throws {
        let knownFlags: Set<String> = ["--host", "--port", "--api-key"]
        let unexpected = CommandSupport.removingKnownFlags(knownFlags, from: arguments)
        guard unexpected.isEmpty else {
            throw StoreError.invalidManifest(usage)
        }

        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let host = CommandSupport.optionalValue(flag: "--host", in: arguments) ?? "127.0.0.1"
        let requestedPort = try resolvePort(arguments: arguments)
        let apiKey = resolveAPIKey(arguments: arguments)

        // Handle "Address already in use" gracefully rather than failing to bind and hanging.
        let port: UInt16
        switch PortConflictResolver.resolve(host: host, port: requestedPort) {
        case .useRequested: port = requestedPort
        case .useAlternate(let alternate): port = alternate
        case .cancelled:
            print("esh serve cancelled — port \(requestedPort) is in use.")
            return
        }

        // One warm pool shared by LLM inference and the persistent speech runtime, so both draw on a
        // single memory budget (M12 follow-up: speech reservation respected; speech evicts under LLM
        // pressure).
        let pool = OpenAICompatibleService.makeLifecycleManager()
        let service = OpenAICompatibleService(
            modelStore: FileModelStore(root: root),
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root),
            toolVersion: toolVersion,
            audioModels: OpenAICompatibleAudioCatalog.ttsModels,
            speech: { request in
                try await AudioSpeechGenerator.generateResponse(request, currentDirectoryURL: currentDirectoryURL,
                                                                lifecycleManager: pool)
            },
            transcribe: SpeechEndpointSupport.transcribeClosure(lifecycleManager: pool),
            webData: WebExperienceData.provider(root: root, toolVersion: toolVersion),
            lifecycleManager: pool,
            root: root,
            artifactStore: FileArtifactStore(root: root)
        )
        let handler = OpenAICompatibleHTTPHandler(service: service, bearerToken: apiKey, toolVersion: toolVersion)
        let server = try OpenAICompatibleLocalServer(host: host, port: port, handler: handler)

        server.start()

        // Voice 2.1 realtime duplex endpoint (WebSocket) on a companion port. Thin clients (browser/simulator)
        // stream mic PCM and receive typed VoiceEvents + binary TTS; the server owns VAD/STT/LLM/TTS + barge-in,
        // sharing the same warm lifecycle pool. Best-effort so it never breaks the HTTP server.
        let voicePort: UInt16 = port == 65535 ? port - 1 : port + 1
        var voiceServerRef: VoiceWebSocketServer?
        do {
            let vStore = FileModelStore(root: root)
            let vInference = ExternalInferenceService(modelStore: vStore, sessionStore: FileSessionStore(root: root),
                                                      cacheStore: FileCacheStore(root: root), lifecycleManager: pool)
            let vInstalls = (try? vStore.listInstalls()) ?? []
            let vLLM = vInstalls.first(where: { $0.spec.backend == .mlx })?.id ?? vInstalls.first?.id
            let vServer = try VoiceWebSocketServer(port: voicePort) { cfg in
                VoiceSessionOrchestrator(
                    config: cfg,
                    transcriber: SpeechRuntimeTranscriber(lifecycleManager: pool),
                    responder: LanguageResponder(inference: vInference, resolveModel: { pin in pin ?? cfg.inferenceModel ?? vLLM }),
                    speaker: BufferedTTSSpeaker(lifecycleManager: pool))
            }
            vServer.start()
            voiceServerRef = vServer
            print("esh Voice realtime (WebSocket) listening on ws://\(host):\(voicePort)/v1/voice/stream")
        } catch {
            fputs("warning: Voice realtime endpoint unavailable: \(error.localizedDescription)\n", stderr)
        }
        _ = voiceServerRef   // retained for the process lifetime

        if host == "0.0.0.0" || host == "::" {
            fputs("warning: binding to \(host) exposes the API — and any loaded model — to other machines on the network.\n", stderr)
            if apiKey == nil {
                fputs("warning: no --api-key set; anyone who can reach this port can use it. Pass --api-key <token> to require auth.\n", stderr)
            }
        }
        let redactedAuth = apiKey == nil ? "disabled" : "enabled"
        print("esh OpenAI-compatible server listening on http://\(host):\(port)")
        print("auth: \(redactedAuth)")
        print("routes: GET /health, GET /web, GET /v1/models, GET /v1/tools, GET /v1/audio/models, GET /api/tags, POST /v1/audio/speech, POST /v1/audio/transcriptions, POST /v1/chat/completions, POST /v1/responses")
        print("press Ctrl+C to stop")

        let signalHandler = SignalHandler()
        signalHandler.wait()
        server.stop()
    }

    private static func resolvePort(arguments: [String]) throws -> UInt16 {
        guard let rawPort = CommandSupport.optionalValue(flag: "--port", in: arguments) else {
            return defaultPort
        }
        guard let parsed = UInt16(rawPort), parsed > 0 else {
            throw StoreError.invalidManifest("Invalid port `\(rawPort)`. " + usage)
        }
        return parsed
    }

    private static func resolveAPIKey(arguments: [String]) -> String? {
        if let apiKey = CommandSupport.optionalValue(flag: "--api-key", in: arguments), apiKey.isEmpty == false {
            return apiKey
        }
        return nil
    }

}

final class SignalHandler {
    private let semaphore = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "esh.signal-handler")
    private var sources: [DispatchSourceSignal] = []

    init(signals: [Int32] = [SIGINT, SIGTERM]) {
        for signalNumber in signals {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.semaphore.signal()
            }
            source.resume()
            sources.append(source)
        }
    }

    func wait() {
        semaphore.wait()
    }
}
