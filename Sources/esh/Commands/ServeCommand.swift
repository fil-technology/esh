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

        let host = CommandSupport.optionalValue(flag: "--host", in: arguments) ?? "127.0.0.1"
        let port = try resolvePort(arguments: arguments)
        let apiKey = resolveAPIKey(arguments: arguments)

        let service = OpenAICompatibleService(
            modelStore: FileModelStore(root: root),
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root),
            toolVersion: toolVersion,
            audioModels: OpenAICompatibleAudioCatalog.ttsModels
        )
        let handler = OpenAICompatibleHTTPHandler(service: service, bearerToken: apiKey)
        let server = try OpenAICompatibleLocalServer(host: host, port: port, handler: handler)

        server.start()
        let redactedAuth = apiKey == nil ? "disabled" : "enabled"
        print("esh OpenAI-compatible server listening on http://\(host):\(port)")
        print("auth: \(redactedAuth)")
        print("routes: GET /health, GET /v1/models, GET /v1/tools, GET /v1/audio/models, GET /api/tags, POST /v1/chat/completions, POST /v1/responses")
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
        if let envValue = ProcessInfo.processInfo.environment["ESH_API_KEY"], envValue.isEmpty == false {
            return envValue
        }
        return nil
    }

}

private final class SignalHandler {
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
