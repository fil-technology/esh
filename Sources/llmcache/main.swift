import Foundation
import LLMCacheCore

do {
    try await CLI().run(arguments: CommandLine.arguments)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}

private struct CLI {
    private let root = PersistenceRoot.default()

    func run(arguments: [String]) async throws {
        let command = Array(arguments.dropFirst())
        guard let head = command.first else {
            printUsage()
            return
        }

        let modelStore = FileModelStore(root: root)
        let modelDownloader = HuggingFaceModelDownloader(modelStore: modelStore)
        let modelService = ModelService(store: modelStore, downloader: modelDownloader)
        let sessionStore = FileSessionStore(root: root)
        let cacheStore = FileCacheStore(root: root)

        switch head {
        case "doctor":
            try DoctorCommand.run()
        case "model":
            try await handleModel(arguments: Array(command.dropFirst()), service: modelService)
        case "session":
            try handleSession(arguments: Array(command.dropFirst()), store: sessionStore)
        case "cache":
            try await handleCache(arguments: Array(command.dropFirst()), store: cacheStore)
        case "chat":
            try await handleChat(arguments: Array(command.dropFirst()), sessionStore: sessionStore)
        default:
            printUsage()
        }
    }

    private func handleModel(arguments: [String], service: ModelService) async throws {
        guard let subcommand = arguments.first else {
            ModelListCommand.run(service: service)
            return
        }

        switch subcommand {
        case "list":
            ModelListCommand.run(service: service)
        case "install":
            guard let repoID = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: llmcache model install <hf-repo-id>")
            }
            try await ModelInstallCommand.run(repoID: repoID, service: service)
        case "inspect":
            guard let modelID = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: llmcache model inspect <model-id>")
            }
            try ModelInspectCommand.run(modelID: modelID, service: service)
        case "remove":
            guard let modelID = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: llmcache model remove <model-id>")
            }
            try ModelRemoveCommand.run(modelID: modelID, service: service)
        default:
            throw StoreError.invalidManifest("Unknown model subcommand: \(subcommand)")
        }
    }

    private func handleSession(arguments: [String], store: SessionStore) throws {
        try SessionCommand.run(arguments: arguments, store: store)
    }

    private func handleCache(arguments: [String], store: CacheStore) async throws {
        guard let subcommand = arguments.first else {
            try CacheInspectCommand.run(arguments: arguments, store: store)
            return
        }

        switch subcommand {
        case "build":
            try await CacheBuildCommand.run(arguments: Array(arguments.dropFirst()))
        case "load":
            try await CacheLoadCommand.run(arguments: Array(arguments.dropFirst()))
        default:
            try CacheInspectCommand.run(arguments: arguments, store: store)
        }
    }

    private func handleChat(arguments: [String], sessionStore: SessionStore) async throws {
        let sessionName = arguments.first ?? "default"
        let app = TUIApplication()
        try await app.run(sessionName: sessionName, sessionStore: sessionStore)
    }

    private func printUsage() {
        print(
            """
            llmcache commands:
              llmcache chat [session-name]
              llmcache doctor
              llmcache model list
              llmcache model install <hf-repo-id>
              llmcache model inspect <model-id>
              llmcache model remove <model-id>
              llmcache session [list|show <uuid>]
              llmcache cache build --session <uuid> [--mode raw|turbo] [--model <id>]
              llmcache cache load --artifact <uuid> --message <text> [--model <id>]
              llmcache cache inspect [artifact-uuid]
            """
        )
    }
}
