import Foundation
import EshCore

/// `esh web [--host 127.0.0.1] [--port 11436] [--no-open]`
/// Launches the local esh server and opens a browser to the Web Chat reference client (served at
/// `/web`). It is a reference client over the canonical esh APIs — not another inference engine.
enum WebCommand {
    static let defaultPort: UInt16 = 11436
    private static let usage = "Usage: esh web [--host 127.0.0.1] [--port <1-65535>] [--no-open]"

    static func run(arguments: [String], root: PersistenceRoot, toolVersion: String?) async throws {
        let knownFlags: Set<String> = ["--host", "--port"]
        let unexpected = CommandSupport.removingKnownFlags(knownFlags, from: arguments)
            .filter { $0 != "--no-open" }
        guard unexpected.isEmpty else { throw StoreError.invalidManifest(usage) }

        let host = CommandSupport.optionalValue(flag: "--host", in: arguments) ?? "127.0.0.1"
        let requestedPort: UInt16 = CommandSupport.optionalValue(flag: "--port", in: arguments)
            .flatMap { UInt16($0) } ?? defaultPort
        let open = !arguments.contains("--no-open")

        // Handle "Address already in use" gracefully: offer to stop an existing esh server on this
        // port, move to a free port, or cancel (auto-selects a free port when non-interactive).
        let port: UInt16
        switch PortConflictResolver.resolve(host: host, port: requestedPort) {
        case .useRequested: port = requestedPort
        case .useAlternate(let alternate): port = alternate
        case .cancelled:
            print("esh web cancelled — port \(requestedPort) is in use.")
            return
        }
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        // Keep MLX models weights-resident across requests so streaming starts immediately instead of
        // reloading the model on every message (the long "generating…" pause). Opt out with
        // ESH_MLX_PERSISTENT=0.
        if ProcessInfo.processInfo.environment["ESH_MLX_PERSISTENT"] == nil {
            setenv("ESH_MLX_PERSISTENT", "1", 1)
        }

        let service = OpenAICompatibleService(
            modelStore: FileModelStore(root: root),
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root),
            toolVersion: toolVersion,
            audioModels: OpenAICompatibleAudioCatalog.ttsModels,
            speech: { request in
                try await AudioSpeechGenerator.generateResponse(request, currentDirectoryURL: currentDirectoryURL)
            },
            transcribe: SpeechEndpointSupport.transcribeClosure(),
            webData: WebExperienceData.provider(root: root, toolVersion: toolVersion)
        )
        // No bearer token: the browser page needs unauthenticated same-origin access to the API.
        let handler = OpenAICompatibleHTTPHandler(service: service, bearerToken: nil, toolVersion: toolVersion)
        let server = try OpenAICompatibleLocalServer(host: host, port: port, handler: handler)
        server.start()

        let url = "http://\(host):\(port)/web"
        print("esh Web Chat: \(url)")
        print("(reference client over the local esh API — press Ctrl+C to stop)")
        if open { openBrowser(url) }

        let signalHandler = SignalHandler()
        signalHandler.wait()
        server.stop()
    }

    private static func openBrowser(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        try? process.run()
    }
}
