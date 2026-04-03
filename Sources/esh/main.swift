import Foundation
import Darwin
import EshCore

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
            try await showDefaultMenu()
            return
        }

        let modelStore = FileModelStore(root: root)
        let modelDownloader = HuggingFaceModelDownloader(modelStore: modelStore)
        let modelService = ModelService(store: modelStore, downloader: modelDownloader)
        let recommendedRegistry = RecommendedModelRegistry()
        let modelCatalogService = ModelCatalogService(
            localCatalog: LocalModelCatalog(store: modelStore),
            huggingFaceCatalog: HuggingFaceModelCatalog(),
            modelStore: modelStore
        )
        let sessionStore = FileSessionStore(root: root)
        let cacheStore = FileCacheStore(root: root)

        switch head {
        case "benchmark":
            try await BenchmarkCommand.run(arguments: Array(command.dropFirst()))
        case "doctor":
            try DoctorCommand.run()
        case "model":
            try await handleModel(arguments: Array(command.dropFirst()), service: modelService, catalogService: modelCatalogService, recommendedRegistry: recommendedRegistry)
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

    private func showDefaultMenu() async throws {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            printUsage()
            return
        }

        let modelStore = FileModelStore(root: root)
        let modelDownloader = HuggingFaceModelDownloader(modelStore: modelStore)
        let modelService = ModelService(store: modelStore, downloader: modelDownloader)
        let recommendedRegistry = RecommendedModelRegistry()
        let modelCatalogService = ModelCatalogService(
            localCatalog: LocalModelCatalog(store: modelStore),
            huggingFaceCatalog: HuggingFaceModelCatalog(),
            modelStore: modelStore
        )
        let sessionStore = FileSessionStore(root: root)
        let cacheStore = FileCacheStore(root: root)

        while true {
            renderDefaultMenu(
                modelCount: (try? modelStore.listInstalls().count) ?? 0,
                sessionCount: (try? sessionStore.listSessions().count) ?? 0,
                cacheCount: (try? cacheStore.listArtifacts().count) ?? 0
            )

            guard let selection = prompt("Choose an option")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selection.isEmpty else {
                continue
            }

            switch selection {
            case "1":
                let sessionName = prompt("Session name (blank for default)")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await handleChat(
                    arguments: [sessionName].compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    },
                    sessionStore: sessionStore
                )
            case "2":
                try ModelRecommendedCommand.run(arguments: [], registry: recommendedRegistry)
                pauseForMenu()
            case "3":
                ModelListCommand.run(service: modelService)
                pauseForMenu()
            case "4":
                guard let query = prompt("Model search query")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !query.isEmpty else {
                    print("Search cancelled.")
                    pauseForMenu()
                    continue
                }
                try await ModelSearchCommand.run(arguments: [query], service: modelCatalogService)
                pauseForMenu()
            case "5":
                guard let repoID = prompt("Repo id or recommended alias")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !repoID.isEmpty else {
                    print("Install cancelled.")
                    pauseForMenu()
                    continue
                }
                try await ModelInstallCommand.run(identifier: repoID, service: modelService, registry: recommendedRegistry)
                pauseForMenu()
            case "6":
                try handleSession(arguments: ["list"], store: sessionStore)
                pauseForMenu()
            case "7":
                try CacheInspectCommand.run(arguments: [], store: cacheStore)
                pauseForMenu()
            case "8":
                try DoctorCommand.run()
                pauseForMenu()
            case "9":
                printUsage()
                pauseForMenu()
            case "10":
                try await BenchmarkCommand.run(arguments: ["history"])
                pauseForMenu()
            case "0", "q", "quit", "exit":
                return
            default:
                print("Unknown option: \(selection)")
                pauseForMenu()
            }
        }
    }

    private func handleModel(arguments: [String], service: ModelService, catalogService: ModelCatalogService, recommendedRegistry: RecommendedModelRegistry) async throws {
        guard let subcommand = arguments.first else {
            ModelListCommand.run(service: service)
            return
        }

        switch subcommand {
        case "recommended":
            try ModelRecommendedCommand.run(arguments: Array(arguments.dropFirst()), registry: recommendedRegistry)
        case "list":
            ModelListCommand.run(service: service)
        case "search":
            try await ModelSearchCommand.run(arguments: Array(arguments.dropFirst()), service: catalogService)
        case "install":
            guard let repoID = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: esh model install <hf-repo-id-or-alias>")
            }
            try await ModelInstallCommand.run(identifier: repoID, service: service, registry: recommendedRegistry)
        case "inspect":
            guard let modelID = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: esh model inspect <model-id>")
            }
            try ModelInspectCommand.run(modelID: modelID, service: service)
        case "remove":
            guard let modelID = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: esh model remove <model-id>")
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
        let modelIdentifier = CommandSupport.optionalValue(flag: "--model", in: arguments)
        let positional = CommandSupport.positionalArguments(in: arguments, knownFlags: ["--model"])
        let sessionName = positional.first ?? "default"
        let app = TUIApplication()
        try await app.run(
            sessionName: sessionName,
            modelIdentifier: modelIdentifier,
            sessionStore: sessionStore
        )
    }

    private func printUsage() {
        print(
            """
            esh commands:
              esh
              esh chat [session-name]
              esh chat [session-name] --model <id-or-repo>
              esh benchmark --session <uuid-or-name> [--model <id-or-repo>] [--message <text>]
              esh benchmark history
              esh doctor
              esh model recommended [--profile chat|code]
              esh model list
              esh model search <query> [--source all|local|hf] [--limit N]
              esh model install <hf-repo-id-or-alias>
              esh model inspect <model-id>
              esh model remove <model-id>
              esh session [list|show <uuid-or-name>|grep <text>]
              esh cache build --session <uuid-or-name> [--mode raw|turbo] [--model <id-or-repo>]
              esh cache load --artifact <uuid> --message <text> [--model <id-or-repo>]
              esh cache inspect [artifact-uuid]
            """
        )
    }

    private func renderDefaultMenu(modelCount: Int, sessionCount: Int, cacheCount: Int) {
        print(
            """

            Esh
            Local-first LLM chat for Apple Silicon

            Installed models: \(modelCount)
            Saved sessions:   \(sessionCount)
            Saved caches:     \(cacheCount)

            1. Chat
            2. Recommended models
            3. List models
            4. Search models
            5. Install model
            6. List sessions
            7. List caches
            8. Doctor
            9. Show CLI help
            10. Benchmark history
            0. Exit
            """
        )
    }

    private func prompt(_ label: String) -> String? {
        print("\(label): ", terminator: "")
        fflush(stdout)
        return readLine()
    }

    private func pauseForMenu() {
        _ = prompt("Press Enter to return to menu")
    }
}
