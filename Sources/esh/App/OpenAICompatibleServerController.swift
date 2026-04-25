import Foundation
import EshCore

final class OpenAICompatibleServerController: @unchecked Sendable {
    static let shared = OpenAICompatibleServerController()

    private let lock = NSLock()
    private var server: OpenAICompatibleLocalServer?
    private var activeHost = "127.0.0.1"
    private var activePort: UInt16 = 11434

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return server != nil
    }

    var baseURL: String? {
        lock.lock()
        defer { lock.unlock() }
        guard server != nil else { return nil }
        return "http://\(activeHost):\(activePort)"
    }

    func start(
        root: PersistenceRoot,
        toolVersion: String?,
        host: String = "127.0.0.1",
        port: UInt16 = 11434,
        apiKey: String? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard server == nil else { return }

        let service = OpenAICompatibleService(
            modelStore: FileModelStore(root: root),
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root),
            toolVersion: toolVersion,
            audioModels: OpenAICompatibleAudioCatalog.ttsModels
        )
        let handler = OpenAICompatibleHTTPHandler(service: service, bearerToken: apiKey)
        let newServer = try OpenAICompatibleLocalServer(host: host, port: port, handler: handler)
        newServer.start()
        server = newServer
        activeHost = host
        activePort = port
    }

    func stop() {
        lock.lock()
        let serverToStop = server
        server = nil
        lock.unlock()

        serverToStop?.stop()
    }

    @discardableResult
    func toggle(root: PersistenceRoot, toolVersion: String?) throws -> Bool {
        if isRunning {
            stop()
            return false
        }
        try start(root: root, toolVersion: toolVersion)
        return true
    }
}
