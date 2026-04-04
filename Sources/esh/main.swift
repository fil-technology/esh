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
            try await handleModel(arguments: Array(command.dropFirst()), service: modelService, catalogService: modelCatalogService)
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
            let modelCount = (try? modelStore.listInstalls().count) ?? 0
            let sessionCount = (try? sessionStore.listSessions().count) ?? 0
            let cacheCount = (try? cacheStore.listArtifacts().count) ?? 0
            switch picker.pick(
                title: StartupBanner.render(
                    modelCount: modelCount,
                    sessionCount: sessionCount,
                    cacheCount: cacheCount
                ),
                subtitle: "Tips: Enter selects. Press n on Chat for a named session. Chat now lets you pick the model before opening.",
                items: menuItems,
                primaryHint: "Enter select",
                secondaryHints: ["n named chat"],
                secondaryKeys: ["n"]
            ) {
            case .selected(0):
                guard let selectedModelID = try await pickChatModel(
                    service: modelService,
                    catalogService: modelCatalogService
                ) else {
                    continue
                }
                try await handleChat(
                    arguments: ["--model", selectedModelID],
                    sessionStore: sessionStore
                )
            case .secondary("n", 0):
                let sessionName = prompt("Session name")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let sessionName, !sessionName.isEmpty else {
                    continue
                }
                guard let selectedModelID = try await pickChatModel(
                    service: modelService,
                    catalogService: modelCatalogService
                ) else {
                    continue
                }
                try await handleChat(
                    arguments: [sessionName, "--model", selectedModelID],
                    sessionStore: sessionStore
                )
            case .selected(1):
                try await showRecommendedModelsMenu(
                    service: modelService,
                    catalogService: modelCatalogService
                )
            case .selected(2):
                try await showInstalledModelsMenu(
                    service: modelService,
                    catalogService: modelCatalogService,
                    sessionStore: sessionStore
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
                    catalogService: modelCatalogService
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
                    catalogService: modelCatalogService
                )
                pauseForMenu()
            case .selected(5):
                try await showSessionsMenu(
                    sessionStore: sessionStore,
                    cacheStore: cacheStore
                )
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

    private func handleModel(arguments: [String], service: ModelService, catalogService: ModelCatalogService) async throws {
        guard let subcommand = arguments.first else {
            ModelListCommand.run(service: service)
            return
        }

        switch subcommand {
        case "recommended":
            try ModelRecommendedCommand.run(arguments: Array(arguments.dropFirst()), service: service)
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
                catalogService: catalogService
            )
        case "open":
            guard let identifier = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: esh model open <model-id-or-alias-or-repo-or-search-term>")
            }
            try await ModelOpenCommand.run(
                identifier: identifier,
                service: service,
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
        let sessionName: String
        if let explicit = positional.first {
            sessionName = explicit
        } else if modelIdentifier != nil {
            sessionName = try nextSessionName(sessionStore: sessionStore)
        } else {
            sessionName = "default"
        }
        let app = TUIApplication()
        try await app.run(
            sessionName: sessionName,
            modelIdentifier: modelIdentifier,
            sessionStore: sessionStore
        )
    }

    private func nextSessionName(sessionStore: SessionStore) throws -> String {
        let existing = try sessionStore.listSessions().map(\.name)
        if !existing.contains("session-1") {
            return "session-1"
        }
        var index = 2
        while existing.contains("session-\(index)") {
            index += 1
        }
        return "session-\(index)"
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
              esh model recommended [--profile chat|code] [--tier good|small|tiny|max] [--tag <tag>] [--backend mlx|gguf|onnx]
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
        print("Press Enter to return to menu", terminator: "")
        fflush(stdout)
        waitForEnter()
        print("")
    }

    private func confirmAction(_ prompt: String) -> Bool {
        print("\(prompt) ", terminator: "")
        fflush(stdout)

        guard isatty(STDIN_FILENO) != 0 else {
            let response = readLine()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            print("")
            return response == "y" || response == "yes"
        }

        let previous = enablePauseRawMode()
        defer { restorePauseMode(previous) }

        while let byte = readPauseByte() {
            switch byte {
            case UInt8(ascii: "y"), UInt8(ascii: "Y"):
                discardBufferedReturnKey()
                print("y")
                return true
            case UInt8(ascii: "n"), UInt8(ascii: "N"), 27, 3:
                discardBufferedReturnKey()
                print("n")
                return false
            case 10, 13:
                print("")
                return false
            default:
                continue
            }
        }

        print("")
        return false
    }

    private func waitForEnter() {
        guard isatty(STDIN_FILENO) != 0 else {
            _ = readLine()
            return
        }

        let previous = enablePauseRawMode()
        defer { restorePauseMode(previous) }

        while let byte = readPauseByte() {
            if byte == 10 || byte == 13 {
                return
            }
        }
    }

    private func enablePauseRawMode() -> termios? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
        return original
    }

    private func restorePauseMode(_ original: termios?) {
        guard var original else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    }

    private func readPauseByte() -> UInt8? {
        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        return count == 1 ? byte : nil
    }

    private func discardBufferedReturnKey() {
        tcflush(STDIN_FILENO, TCIFLUSH)
    }

    private func showRecommendedModelsMenu(
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws {
        let models = service.listRecommended()
        guard !models.isEmpty else {
            print("No recommended models found.")
            pauseForMenu()
            return
        }

        let items = models.map { model in
            let features = featureBadgeText(ModelFeatureClassifier.features(for: model))
            return InteractiveListPicker.Item(
                title: "\(model.id)  \(features)",
                detail: "\(model.tier.displayName) | \(model.quantization) | \(model.memoryHint) | \(model.sizeHint) | \(model.repoID)"
            )
        }
        let picker = InteractiveListPicker()
        switch picker.pick(
            title: "Recommended Models",
            subtitle: "Enter installs the selected model. Press o to open the model page.",
            items: items,
            primaryHint: "Enter install",
            secondaryHints: ["o open page"],
            secondaryKeys: ["o"]
        ) {
        case .selected(let index):
            let model = models[index]
            try await ModelInstallCommand.run(
                identifier: model.id,
                service: service,
                catalogService: catalogService
            )
        case .secondary("o", let index):
            let model = models[index]
            try await ModelOpenCommand.run(
                identifier: model.id,
                service: service,
                catalogService: catalogService
            )
        default:
            return
        }
        pauseForMenu()
    }

    private func pickChatModel(
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws -> String? {
        let installs = try service.list()
        guard !installs.isEmpty else {
            print("No installed models.")
            pauseForMenu()
            return nil
        }

        let backend = MLXBackend()
        let modelEntries = installs.map { install -> (install: ModelInstall, incompatibility: String?) in
            let incompatibility = try? backend.validateChatModel(for: install)
            return (install, incompatibility ?? nil)
        }
        let picker = InteractiveListPicker()
        let items = modelEntries.map { entry in
            let install = entry.install
            let incompatibility = entry.incompatibility
            let features = featureBadgeText(ModelFeatureClassifier.features(for: install))
            let compatibility = incompatibility == nil ? "chat-ready" : "incompatible"
            return InteractiveListPicker.Item(
                title: "\(install.id)  \(features)",
                detail: "\(compatibility) | \(ByteFormatting.string(for: install.sizeBytes)) | \(install.installPath)"
            )
        }

        while true {
            switch picker.pick(
                title: "Choose Chat Model",
                subtitle: "Enter starts chat with the selected model. Press o to open its model page or d to delete it.",
                items: items,
                primaryHint: "Enter start chat",
                secondaryHints: ["o open page", "d delete"],
                secondaryKeys: ["o", "d"]
            ) {
            case .selected(let index):
                let entry = modelEntries[index]
                if let incompatibility = entry.incompatibility {
                    print("Model \(entry.install.id) is not chat-compatible with the current MLX runtime: \(incompatibility)")
                    pauseForMenu()
                    return nil
                }
                return entry.install.id
            case .secondary("o", let index):
                try await ModelOpenCommand.run(
                    identifier: modelEntries[index].install.id,
                    service: service,
                    catalogService: catalogService
                )
                pauseForMenu()
                return nil
            case .secondary("d", let index):
                let install = modelEntries[index].install
                guard confirmAction("Delete \(install.id)? [y/N]") else {
                    continue
                }
                try ModelRemoveCommand.run(modelID: install.id, service: service)
                pauseForMenu()
                return nil
            default:
                return nil
            }
        }
    }

    private func showInstalledModelsMenu(
        service: ModelService,
        catalogService: ModelCatalogService,
        sessionStore: SessionStore
    ) async throws {
        let picker = InteractiveListPicker()

        while true {
            let installs = try service.list()
            guard !installs.isEmpty else {
                print("No installed models.")
                pauseForMenu()
                return
            }

            let items = installs.map { install in
                let features = featureBadgeText(ModelFeatureClassifier.features(for: install))
                return InteractiveListPicker.Item(
                    title: "\(install.id)  \(features)",
                    detail: install.installPath
                )
            }

            switch picker.pick(
                title: "Installed Models",
                subtitle: "Enter opens the model page. Press c to chat with the selected model or d to delete it.",
                items: items,
                primaryHint: "Enter open page",
                secondaryHints: ["c chat", "d delete"],
                secondaryKeys: ["c", "d"]
            ) {
            case .selected(let index):
                let install = installs[index]
                try await ModelOpenCommand.run(
                    identifier: install.id,
                    service: service,
                    catalogService: catalogService
                )
                pauseForMenu()
                return
            case .secondary("c", let index):
                let install = installs[index]
                try await handleChat(
                    arguments: ["--model", install.id],
                    sessionStore: sessionStore
                )
                return
            case .secondary("d", let index):
                let install = installs[index]
                guard confirmAction("Delete \(install.id)? [y/N]") else {
                    continue
                }
                try ModelRemoveCommand.run(modelID: install.id, service: service)
                pauseForMenu()
            default:
                return
            }
        }
    }

    private func showSessionsMenu(
        sessionStore: SessionStore,
        cacheStore: CacheStore
    ) async throws {
        let sessions = try sessionStore.listSessions()
        guard !sessions.isEmpty else {
            print("No saved sessions.")
            pauseForMenu()
            return
        }

        let artifacts = try cacheStore.listArtifacts()
        let latestCacheBySession = Dictionary(
            grouping: artifacts,
            by: { $0.manifest.sessionID }
        ).compactMapValues { group in
            group.max { lhs, rhs in
                lhs.manifest.createdAt < rhs.manifest.createdAt
            }
        }

        let items = sessions.map { session in
            let model = session.modelID ?? "-"
            let cacheCount = artifacts.filter { $0.manifest.sessionID == session.id }.count
            let cacheSummary: String
            if let latest = latestCacheBySession[session.id] {
                cacheSummary = "\(cacheCount) cache | \(latest.manifest.cacheMode.rawValue)"
            } else {
                cacheSummary = "0 cache"
            }

            return InteractiveListPicker.Item(
                title: "\(session.name) [\(CommandSupport.shortID(session.id))]",
                detail: "\(model) | \(cacheSummary) | \(session.messages.count) messages"
            )
        }

        let picker = InteractiveListPicker()
        switch picker.pick(
            title: "Saved Sessions",
            subtitle: "Enter opens the selected session in chat.",
            items: items,
            primaryHint: "Enter open session"
        ) {
        case .selected(let index):
            let session = sessions[index]
            try await handleChat(
                arguments: [session.id.uuidString],
                sessionStore: sessionStore
            )
        default:
            return
        }
    }

    private func showSearchModelsMenu(
        query: String,
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws {
        let results = try await catalogService.search(query: query, sourceFilter: .all, limit: 10)
        guard !results.isEmpty else {
            print("No models found for \"\(query)\".")
            pauseForMenu()
            return
        }

        let items = results.map { result in
            let features = featureBadgeText(ModelFeatureClassifier.features(for: result))
            let source = result.source == .huggingFace ? "hf" : "local"
            let state = result.isInstalled ? "installed" : "-"
            let kind = result.backend?.rawValue ?? result.tags.first ?? "-"
            let size = result.sizeBytes.map(ByteFormatting.string(for:)) ?? "-"
            let downloads = result.downloads.map(compactNumber(_:)) ?? "-"
            let date = result.updatedAt.map(menuDateFormatter.string(from:)) ?? "-"
            return InteractiveListPicker.Item(
                title: "\(result.displayName)  \(features)",
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
                catalogService: catalogService
            )
        case .secondary("i", let index):
            let result = results[index]
            try await ModelInstallCommand.run(
                identifier: result.modelSource.reference,
                service: service,
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

    private func featureBadgeText(_ features: [String]) -> String {
        guard !features.isEmpty else { return "[mlx]" }
        return features.prefix(3).map { "[\($0)]" }.joined(separator: " ")
    }
}
