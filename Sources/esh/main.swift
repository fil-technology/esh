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
        let picker = InteractiveListPicker()

        while true {
            let menuItems = makeDefaultMenuItems(
                modelCount: (try? modelStore.listInstalls().count) ?? 0,
                sessionCount: (try? sessionStore.listSessions().count) ?? 0,
                cacheCount: (try? cacheStore.listArtifacts().count) ?? 0
            )
            switch picker.pick(
                title: "Esh",
                subtitle: "Local-first LLM chat for Apple Silicon",
                items: menuItems,
                primaryHint: "Enter select"
            ) {
            case .selected(0):
                let sessionName = prompt("Session name (blank for default)")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await handleChat(
                    arguments: [sessionName].compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    },
                    sessionStore: sessionStore
                )
            case .selected(1):
                try await showRecommendedModelsMenu(
                    service: modelService,
                    catalogService: modelCatalogService,
                    registry: recommendedRegistry
                )
            case .selected(2):
                try await showInstalledModelsMenu(
                    service: modelService,
                    catalogService: modelCatalogService,
                    registry: recommendedRegistry
                )
            case .selected(3):
                guard let query = prompt("Model search query")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !query.isEmpty else {
                    continue
                }
                try await showSearchModelsMenu(
                    query: query,
                    service: modelService,
                    catalogService: modelCatalogService,
                    registry: recommendedRegistry
                )
            case .selected(4):
                guard let repoID = prompt("Repo id, alias, or search term")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !repoID.isEmpty else {
                    continue
                }
                try await ModelInstallCommand.run(
                    identifier: repoID,
                    service: modelService,
                    registry: recommendedRegistry,
                    catalogService: modelCatalogService
                )
                pauseForMenu()
            case .selected(5):
                try handleSession(arguments: ["list"], store: sessionStore)
                pauseForMenu()
            case .selected(6):
                try CacheInspectCommand.run(arguments: [], store: cacheStore)
                pauseForMenu()
            case .selected(7):
                try DoctorCommand.run()
                pauseForMenu()
            case .selected(8):
                printUsage()
                pauseForMenu()
            case .selected(9):
                try await BenchmarkCommand.run(arguments: ["history"])
                pauseForMenu()
            case .cancelled:
                return
            default:
                continue
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
                throw StoreError.invalidManifest("Usage: esh model install <hf-repo-id-or-alias-or-search-term>")
            }
            try await ModelInstallCommand.run(
                identifier: repoID,
                service: service,
                registry: recommendedRegistry,
                catalogService: catalogService
            )
        case "open":
            guard let identifier = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: esh model open <model-id-or-alias-or-repo-or-search-term>")
            }
            try await ModelOpenCommand.run(
                identifier: identifier,
                service: service,
                registry: recommendedRegistry,
                catalogService: catalogService
            )
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
              esh model install <hf-repo-id-or-alias-or-search-term>
              esh model open <model-id-or-alias-or-repo-or-search-term>
              esh model inspect <model-id>
              esh model remove <model-id>
              esh session [list|show <uuid-or-name>|grep <text>]
              esh cache build --session <uuid-or-name> [--mode raw|turbo] [--model <id-or-repo>]
              esh cache load --artifact <uuid> --message <text> [--model <id-or-repo>]
              esh cache inspect [artifact-uuid]
            """
        )
    }

    private func makeDefaultMenuItems(modelCount: Int, sessionCount: Int, cacheCount: Int) -> [InteractiveListPicker.Item] {
        [
            .init(title: "Chat", detail: "Open the interactive chat TUI"),
            .init(title: "Recommended models", detail: "Fast setup presets"),
            .init(title: "List models", detail: "\(modelCount) installed"),
            .init(title: "Search models", detail: "Find MLX-compatible models"),
            .init(title: "Install model", detail: "Install by alias, repo id, or search"),
            .init(title: "List sessions", detail: "\(sessionCount) saved"),
            .init(title: "List caches", detail: "\(cacheCount) saved"),
            .init(title: "Doctor", detail: "Check Python, bridge, and runtime"),
            .init(title: "Show CLI help", detail: "Print all commands"),
            .init(title: "Benchmark history", detail: "Past raw vs turbo runs")
        ]
    }

    private func prompt(_ label: String) -> String? {
        print("\(label): ", terminator: "")
        fflush(stdout)
        return readLine()
    }

    private func pauseForMenu() {
        _ = prompt("Press Enter to return to menu")
    }

    private func showRecommendedModelsMenu(
        service: ModelService,
        catalogService: ModelCatalogService,
        registry: RecommendedModelRegistry
    ) async throws {
        let models = registry.list()
        guard !models.isEmpty else {
            print("No recommended models found.")
            pauseForMenu()
            return
        }

        let items = models.map { model in
            InteractiveListPicker.Item(
                title: "\(model.id)  \(model.profile.rawValue)  \(model.tier.rawValue)",
                detail: "\(model.memoryHint) | \(model.sizeHint) | \(model.repoID)"
            )
        }
        let picker = InteractiveListPicker()
        switch picker.pick(
            title: "Recommended Models",
            subtitle: "Enter opens the model page. Press i to install the selected model.",
            items: items,
            primaryHint: "Enter open page",
            secondaryHints: ["i install"],
            secondaryKeys: ["i"]
        ) {
        case .selected(let index):
            let model = models[index]
            try await ModelOpenCommand.run(
                identifier: model.id,
                service: service,
                registry: registry,
                catalogService: catalogService
            )
        case .secondary("i", let index):
            let model = models[index]
            try await ModelInstallCommand.run(
                identifier: model.id,
                service: service,
                registry: registry,
                catalogService: catalogService
            )
        default:
            return
        }
        pauseForMenu()
    }

    private func showInstalledModelsMenu(
        service: ModelService,
        catalogService: ModelCatalogService,
        registry: RecommendedModelRegistry
    ) async throws {
        let installs = try service.list()
        guard !installs.isEmpty else {
            print("No installed models.")
            pauseForMenu()
            return
        }
        let items = installs.map { install in
            InteractiveListPicker.Item(
                title: "\(install.id)  \(ByteFormatting.string(for: install.sizeBytes))",
                detail: install.installPath
            )
        }
        let picker = InteractiveListPicker()
        switch picker.pick(
            title: "Installed Models",
            subtitle: "Enter opens the selected model page in your browser.",
            items: items,
            primaryHint: "Enter open page"
        ) {
        case .selected(let index):
            let install = installs[index]
            try await ModelOpenCommand.run(
                identifier: install.id,
                service: service,
                registry: registry,
                catalogService: catalogService
            )
        default:
            return
        }
        pauseForMenu()
    }

    private func showSearchModelsMenu(
        query: String,
        service: ModelService,
        catalogService: ModelCatalogService,
        registry: RecommendedModelRegistry
    ) async throws {
        let results = try await catalogService.search(query: query, sourceFilter: .all, limit: 10)
        guard !results.isEmpty else {
            print("No models found for \"\(query)\".")
            pauseForMenu()
            return
        }

        let items = results.map { result in
            let source = result.source == .huggingFace ? "hf" : "local"
            let state = result.isInstalled ? "installed" : "-"
            let kind = result.backend?.rawValue ?? result.tags.first ?? "-"
            let size = result.sizeBytes.map(ByteFormatting.string(for:)) ?? "-"
            let downloads = result.downloads.map(compactNumber(_:)) ?? "-"
            let date = result.updatedAt.map(menuDateFormatter.string(from:)) ?? "-"
            return InteractiveListPicker.Item(
                title: "\(result.displayName)",
                detail: "\(source) | \(state) | \(kind) | \(size) | \(downloads) | \(date)"
            )
        }
        let picker = InteractiveListPicker()
        switch picker.pick(
            title: "Model Search: \(query)",
            subtitle: "Enter opens the selected model page. Press i to install it.",
            items: items,
            primaryHint: "Enter open page",
            secondaryHints: ["i install"],
            secondaryKeys: ["i"]
        ) {
        case .selected(let index):
            let result = results[index]
            try await ModelOpenCommand.run(
                identifier: result.modelSource.reference,
                service: service,
                registry: registry,
                catalogService: catalogService
            )
        case .secondary("i", let index):
            let result = results[index]
            try await ModelInstallCommand.run(
                identifier: result.modelSource.reference,
                service: service,
                registry: registry,
                catalogService: catalogService
            )
        default:
            return
        }
        pauseForMenu()
    }

    private func compactNumber(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    private var menuDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }
}
