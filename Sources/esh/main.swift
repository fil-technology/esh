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

    private func showDefaultMenu() async throws {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            printUsage()
            return
        }

        let modelStore = FileModelStore(root: root)
        let modelDownloader = HuggingFaceModelDownloader(modelStore: modelStore)
        let modelService = ModelService(store: modelStore, downloader: modelDownloader)
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
                ModelListCommand.run(service: modelService)
                pauseForMenu()
            case "3":
                guard let repoID = prompt("Hugging Face repo id")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !repoID.isEmpty else {
                    print("Install cancelled.")
                    pauseForMenu()
                    continue
                }
                try await ModelInstallCommand.run(repoID: repoID, service: modelService)
                pauseForMenu()
            case "4":
                try handleSession(arguments: ["list"], store: sessionStore)
                pauseForMenu()
            case "5":
                try CacheInspectCommand.run(arguments: [], store: cacheStore)
                pauseForMenu()
            case "6":
                try DoctorCommand.run()
                pauseForMenu()
            case "7":
                printUsage()
                pauseForMenu()
            case "0", "q", "quit", "exit":
                return
            default:
                print("Unknown option: \(selection)")
                pauseForMenu()
            }
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
                throw StoreError.invalidManifest("Usage: esh model install <hf-repo-id>")
            }
            try await ModelInstallCommand.run(repoID: repoID, service: service)
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
        let sessionName = arguments.first ?? "default"
        let app = TUIApplication()
        try await app.run(sessionName: sessionName, sessionStore: sessionStore)
    }

    private func printUsage() {
        print(
            """
            esh commands:
              esh
              esh chat [session-name]
              esh doctor
              esh model list
              esh model install <hf-repo-id>
              esh model inspect <model-id>
              esh model remove <model-id>
              esh session [list|show <uuid>]
              esh cache build --session <uuid> [--mode raw|turbo] [--model <id>]
              esh cache load --artifact <uuid> --message <text> [--model <id>]
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
            2. List models
            3. Install model
            4. List sessions
            5. List caches
            6. Doctor
            7. Show CLI help
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
