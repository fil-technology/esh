import Foundation
import Darwin
import EshCore

do {
    try PackagedRuntimeBootstrap.configureEnvironmentIfNeeded()
    try await CLI().run(arguments: CommandLine.arguments)
} catch is CLIHandledError {
    Foundation.exit(1)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}

struct CLIHandledError: Error {}

private struct CLI {
    private let root = PersistenceRoot.default()
    private let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

    private struct ChatLaunchSettings {
        let cacheMode: CacheMode
        let intent: SessionIntent
        let autosaveEnabled: Bool
    }

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
        case "capabilities":
            try CapabilitiesCommand.run(arguments: Array(command.dropFirst()), root: root, toolVersion: AppVersionResolver.currentVersion())
        case "benchmark":
            try await BenchmarkCommand.run(arguments: Array(command.dropFirst()))
        case "doctor":
            try DoctorCommand.run()
        case "version":
            print(AppVersionResolver.currentVersion() ?? "unknown")
        case "update":
            await showUpdateStatus()
        case "model":
            try await handleModel(arguments: Array(command.dropFirst()), service: modelService, catalogService: modelCatalogService)
        case "session":
            try handleSession(arguments: Array(command.dropFirst()), store: sessionStore)
        case "cache":
            try await handleCache(arguments: Array(command.dropFirst()), store: cacheStore, currentDirectoryURL: currentDirectoryURL)
        case "agent":
            try await AgentCommand.run(arguments: Array(command.dropFirst()), currentDirectoryURL: currentDirectoryURL)
        case "calibrate":
            try CalibrateCommand.run(arguments: Array(command.dropFirst()))
        case "context":
            try ContextCommand.run(arguments: Array(command.dropFirst()), currentDirectoryURL: currentDirectoryURL)
        case "run":
            try RunCommand.run(arguments: Array(command.dropFirst()), currentDirectoryURL: currentDirectoryURL)
        case "infer":
            try await InferCommand.run(arguments: Array(command.dropFirst()), root: root)
        case "read":
            try ReadCommand.run(arguments: Array(command.dropFirst()), currentDirectoryURL: currentDirectoryURL)
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
        var didOfferStarterInstall = false
        let updateNotice = await ReleaseUpdateService(persistenceRoot: root).checkForUpdate()

        while true {
            let modelCount = (try? modelStore.listInstalls().count) ?? 0
            let sessionCount = (try? sessionStore.listSessions().count) ?? 0
            let cacheCount = (try? cacheStore.listArtifacts().count) ?? 0
            if modelCount == 0 && !didOfferStarterInstall {
                didOfferStarterInstall = true
                StartupBanner.animateIfNeeded(
                    modelCount: modelCount,
                    sessionCount: sessionCount,
                    cacheCount: cacheCount
                )
                try await showStarterModelsMenu(
                    service: modelService,
                    catalogService: modelCatalogService,
                    header: StartupBanner.render(
                        modelCount: modelCount,
                        sessionCount: sessionCount,
                        cacheCount: cacheCount
                    ),
                    title: "No Models Installed Yet",
                    subtitle: "Start with a small proven preset now, or press a to browse the full supported list."
                )
                continue
            }

            let menuItems = makeDefaultMenuItems(
                modelCount: modelCount,
                sessionCount: sessionCount,
                cacheCount: cacheCount
            )
            StartupBanner.animateIfNeeded(
                modelCount: modelCount,
                sessionCount: sessionCount,
                cacheCount: cacheCount
            )
            switch picker.pick(
                title: StartupBanner.render(
                    modelCount: modelCount,
                    sessionCount: sessionCount,
                    cacheCount: cacheCount
                ),
                subtitle: launcherSubtitle(updateNotice: updateNotice),
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
                guard let launchSettings = chooseChatLaunchSettings() else {
                    continue
                }
                printBusy("Opening chat with \(selectedModelID)…")
                try await handleChat(
                    arguments: ["--model", selectedModelID, "--cache-mode", launchSettings.cacheMode.rawValue, "--intent", launchSettings.intent.rawValue, "--autosave", launchSettings.autosaveEnabled ? "on" : "off"],
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
                guard let launchSettings = chooseChatLaunchSettings() else {
                    continue
                }
                printBusy("Opening chat with \(selectedModelID)…")
                try await handleChat(
                    arguments: [sessionName, "--model", selectedModelID, "--cache-mode", launchSettings.cacheMode.rawValue, "--intent", launchSettings.intent.rawValue, "--autosave", launchSettings.autosaveEnabled ? "on" : "off"],
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
                printBusy("Preparing install for \(repoID)…")
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
                try await showCachesMenu(cacheStore: cacheStore)
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
        case "check":
            try await ModelCheckCommand.run(
                arguments: Array(arguments.dropFirst()),
                service: service,
                catalogService: catalogService
            )
        case "install":
            let variant = CommandSupport.optionalValue(flag: "--variant", in: Array(arguments.dropFirst()))
            let positional = CommandSupport.positionalArguments(in: Array(arguments.dropFirst()), knownFlags: ["--variant"])
            guard let repoID = positional.first else {
                throw StoreError.invalidManifest("Usage: esh model install <hf-repo-id-or-alias-or-search-term> [--variant <name>]")
            }
            try await ModelInstallCommand.run(
                identifier: repoID,
                variant: variant,
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

    private func handleCache(arguments: [String], store: CacheStore, currentDirectoryURL: URL) async throws {
        guard let subcommand = arguments.first else {
            try CacheInspectCommand.run(arguments: arguments, store: store)
            return
        }

        switch subcommand {
        case "build":
            try await CacheBuildCommand.run(arguments: Array(arguments.dropFirst()), currentDirectoryURL: currentDirectoryURL)
        case "load":
            try await CacheLoadCommand.run(arguments: Array(arguments.dropFirst()))
        default:
            try CacheInspectCommand.run(arguments: arguments, store: store)
        }
    }

    private func handleChat(arguments: [String], sessionStore: SessionStore) async throws {
        let modelIdentifier = CommandSupport.optionalValue(flag: "--model", in: arguments)
        let cacheModeValue = CommandSupport.optionalValue(flag: "--cache-mode", in: arguments)
        let intentValue = CommandSupport.optionalValue(flag: "--intent", in: arguments)
        let autosaveValue = CommandSupport.optionalValue(flag: "--autosave", in: arguments)
        let positional = CommandSupport.positionalArguments(in: arguments, knownFlags: ["--model", "--cache-mode", "--intent", "--autosave"])
        let preferredCacheMode = cacheModeValue.flatMap { CacheMode(rawValue: $0.lowercased()) }
        let preferredIntent = intentValue.flatMap { SessionIntent(rawValue: $0.lowercased()) }
        let preferredAutosaveEnabled = autosaveValue.map { value in
            switch value.lowercased() {
            case "on", "true", "yes", "1":
                true
            default:
                false
            }
        }
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
            preferredCacheMode: preferredCacheMode,
            preferredIntent: preferredIntent,
            preferredAutosaveEnabled: preferredAutosaveEnabled,
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
              esh version
              esh update
              esh chat [session-name]
              esh chat [session-name] --model <id-or-repo> [--cache-mode raw|turbo|triattention|auto] [--intent chat|code|documentqa|agentrun|multimodal] [--autosave on|off]
              esh benchmark --session <uuid-or-name> [--model <id-or-repo>] [--message <text>]
              esh benchmark history
              esh capabilities
              esh calibrate --method triattention --model <installed-model-id> [--max-tokens N] [--calibration-file <path>]
              esh context build
              esh context status
              esh context query <text> [--limit N] [--run <id>]
              esh context plan <task> [--limit N] [--snippets N] [--run <id>]
              esh context eval <fixture.json> [--limit N]
              esh run start [name]
              esh run status <id>
              esh run note <id> [--hypothesis <text>] [--finding <text>] [--decision <text>] [--pending <text>] [--complete <text>] [--status <value>]
              esh run export <id>
              esh read symbol <name> [--run <id>]
              esh read references <name> [--limit N] [--run <id>]
              esh read related <name-or-path> [--limit N] [--run <id>]
              esh read file <path> --range start:end [--run <id>]
              esh doctor
              esh infer --input <path-or->
              esh infer --model <id-or-repo> --message <text> [--system <text>] [--artifact <uuid>] [--max-tokens N] [--temperature T] [--cache-mode raw|turbo|triattention|auto] [--intent chat|code|documentqa|agentrun|multimodal] [--session-name <name>]
              esh model recommended [--profile chat|code] [--tier good|small|tiny|max] [--tag <tag>] [--backend mlx|gguf|onnx]
              esh model list
              esh model search <query> [--source all|local|hf] [--limit N]
              esh model check <model-or-repo> [--backend mlx|gguf|auto] [--context N] [--variant <name>] [--json] [--strict] [--offline]
              esh model install <hf-repo-id-or-alias-or-search-term> [--variant <name>]
              esh model open <model-id-or-alias-or-repo-or-search-term>
              esh model inspect <model-id>
              esh model remove <model-id>
              esh session [list|show <uuid-or-name>|grep <text>]
              esh cache build --session <uuid-or-name> [--mode raw|turbo|triattention|auto] [--intent chat|code|documentqa|agentrun|multimodal] [--model <id-or-repo>] [--task <text>]
              esh cache load --artifact <uuid> --message <text> [--model <id-or-repo>]
              esh cache inspect [artifact-uuid]
              esh agent run <task> --model <id-or-repo> [--steps N] [--run <id-or-name>]
              esh agent continue --run <id> --model <id-or-repo> [--steps N] [task]
            """
        )
    }

    private func showUpdateStatus() async {
        let current = AppVersionResolver.currentVersion() ?? "unknown"
        if let notice = await ReleaseUpdateService(persistenceRoot: root).checkForUpdate() {
            print("current: \(notice.currentVersion)")
            print("latest: \(notice.latestVersion)")
            print("update: \(notice.upgradeCommand)")
            return
        }

        print("current: \(current)")
        print("status: up to date or unable to verify right now")
        print("update: brew upgrade --cask esh")
    }

    private func launcherSubtitle(updateNotice: ReleaseUpdateNotice?) -> String {
        let base = "Tips: Enter selects. Press n on Chat for a named session. Chat now lets you pick the model before opening."
        guard let updateNotice else {
            return base
        }
        return base + "  Update available: \(updateNotice.latestVersion). Run \(updateNotice.upgradeCommand)."
    }

    private func makeDefaultMenuItems(modelCount: Int, sessionCount: Int, cacheCount: Int) -> [InteractiveListPicker.Item] {
        [
            .init(title: "Chat", detail: "Open the interactive chat TUI"),
            .init(title: "Recommended models", detail: "Fast setup presets"),
            .init(title: "List models", detail: "\(modelCount) installed"),
            .init(title: "Search models", detail: "Find MLX and GGUF models"),
            .init(title: "Install model", detail: "Install by alias, repo id, or search"),
            .init(title: "List sessions", detail: "\(sessionCount) saved"),
            .init(title: "List caches", detail: "\(cacheCount) saved"),
            .init(title: "Doctor", detail: "Check Python, bridge, and runtime"),
            .init(title: "Show CLI help", detail: "Print all commands"),
            .init(title: "Benchmark history", detail: "Past raw vs turbo runs")
        ]
    }

    private func starterModels(service: ModelService, backend: BackendKind) -> [RecommendedModel] {
        let preferredIDs = backend == .mlx
            ? [
                "qwen-2-5-0-5b",
                "llama-3-2-3b",
                "qwen-2-5-coder-7b",
                "mistral-small-24b",
                "qwen-3-5-9b-optiq"
            ]
            : [
                "llama-3-2-3b-gguf",
                "qwen-2-5-coder-7b-gguf",
                "deepseek-r1-qwen-14b-gguf"
            ]
        return preferredIDs.compactMap { service.resolveRecommended(alias: $0) }
    }

    private func prompt(_ label: String) -> String? {
        InteractiveTextPrompt().capture(label: label)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chooseChatLaunchSettings() -> ChatLaunchSettings? {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            return ChatLaunchSettings(cacheMode: .automatic, intent: .chat, autosaveEnabled: false)
        }

        let prompt = InteractiveChoicePrompt()
        guard let selected = prompt.choose(
            title: "Chat Launch Settings",
            message: "Choose how this chat session should start.",
            details: [
                "Quick starts with automatic KV mode and autosave off.",
                "Automatic prefers TriAttention for code and TurboQuant for retrieval-style work.",
                "Autosave writes the session automatically after each reply."
            ],
            choices: [
                .init(key: "q", label: "Quick"),
                .init(key: "a", label: "Autosave"),
                .init(key: "c", label: "Code"),
                .init(key: "d", label: "Doc QA")
            ],
            footer: "←/→ navigate • enter confirm • < back • esc cancel"
        ) else {
            return nil
        }

        switch selected {
        case "a":
            return ChatLaunchSettings(cacheMode: .automatic, intent: .chat, autosaveEnabled: true)
        case "c":
            return ChatLaunchSettings(cacheMode: .automatic, intent: .code, autosaveEnabled: false)
        case "d":
            return ChatLaunchSettings(cacheMode: .automatic, intent: .documentQA, autosaveEnabled: false)
        default:
            return ChatLaunchSettings(cacheMode: .automatic, intent: .chat, autosaveEnabled: false)
        }
    }

    private func pauseForMenu() {
        print("Press Enter to return to menu", terminator: "")
        fflush(stdout)
        waitForEnter()
        print("")
    }

    private func confirmAction(_ prompt: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            print("\(prompt) ", terminator: "")
            fflush(stdout)
            let response = readLine()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            print("")
            return response == "y" || response == "yes"
        }

        let promptView = InteractiveChoicePrompt()
        return promptView.choose(
            title: "Confirm Action",
            message: prompt,
            choices: [
                .init(key: "y", label: "Yes"),
                .init(key: "n", label: "No")
            ],
            footer: "←/→ navigate • enter confirm • < back • esc cancel"
        ) == "y"
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
        let picker = InteractiveListPicker()
        var selectedBackend: BackendKind = .mlx

        while true {
            let models = service.listRecommended(backend: selectedBackend)
            let items = recommendedMenuItems(for: models, backend: selectedBackend)
            let subtitle = recommendedMenuSubtitle(for: selectedBackend, isEmpty: models.isEmpty)

            switch picker.pick(
                title: "Recommended Models [\(selectedBackend.rawValue.uppercased())]",
                subtitle: subtitle,
                items: items,
                primaryHint: models.isEmpty ? "Enter no-op" : "Enter install",
                secondaryHints: ["m mlx", "g gguf", "s search", "o open page"],
                secondaryKeys: ["m", "g", "s", "o"]
            ) {
            case .selected(let index):
                if index == 0 {
                    selectedBackend = .mlx
                    continue
                }
                if index == 1 {
                    selectedBackend = .gguf
                    continue
                }
                let modelIndex = index - 2
                guard models.indices.contains(modelIndex) else {
                    continue
                }
                let model = models[modelIndex]
                try await ModelInstallCommand.run(
                    identifier: model.id,
                    service: service,
                    catalogService: catalogService
                )
                pauseForMenu()
                return
            case .secondary("m", _):
                selectedBackend = .mlx
            case .secondary("g", _):
                selectedBackend = .gguf
            case .secondary("s", _):
                guard let query = prompt("Model search query"), !query.isEmpty else {
                    continue
                }
                try await showSearchModelsMenu(
                    query: query,
                    service: service,
                    catalogService: catalogService
                )
                return
            case .secondary("o", let index):
                let modelIndex = index - 2
                guard models.indices.contains(modelIndex) else {
                    continue
                }
                let model = models[modelIndex]
                try await ModelOpenCommand.run(
                    identifier: model.id,
                    service: service,
                    catalogService: catalogService
                )
                continue
            default:
                return
            }
        }
    }

    private func showStarterModelsMenu(
        service: ModelService,
        catalogService: ModelCatalogService,
        header: String? = nil,
        title: String,
        subtitle: String
    ) async throws {
        let picker = InteractiveListPicker()
        var selectedBackend: BackendKind = .mlx

        while true {
            let models = starterModels(service: service, backend: selectedBackend)
            let items = starterMenuItems(for: models, backend: selectedBackend)
            let starterSubtitle = starterMenuSubtitle(
                base: subtitle,
                backend: selectedBackend,
                isEmpty: models.isEmpty
            )

            switch picker.pick(
                title: starterMenuTitle(
                    header: header,
                    title: title,
                    backend: selectedBackend
                ),
                subtitle: starterSubtitle,
                items: items,
                primaryHint: models.isEmpty ? "Enter no-op" : "Enter install",
                secondaryHints: ["m mlx", "g gguf", "s search", "a all presets", "o open page"],
                secondaryKeys: ["m", "g", "s", "a", "o"]
            ) {
            case .selected(let index):
                if index == 0 {
                    selectedBackend = .mlx
                    continue
                }
                if index == 1 {
                    selectedBackend = .gguf
                    continue
                }

                let modelStartIndex = 2
                let searchIndex = modelStartIndex + models.count
                let browseIndex = searchIndex + 1
                let modelIndex = index - modelStartIndex

                if models.indices.contains(modelIndex) {
                    let model = models[modelIndex]
                    try await ModelInstallCommand.run(
                        identifier: model.id,
                        service: service,
                        catalogService: catalogService
                    )
                    pauseForMenu()
                    return
                }

                if index == searchIndex {
                    guard let query = prompt("Model search query"), !query.isEmpty else {
                        continue
                    }
                    try await showSearchModelsMenu(
                        query: query,
                        service: service,
                        catalogService: catalogService
                    )
                    return
                }

                if index == browseIndex {
                    try await showRecommendedModelsMenu(
                        service: service,
                        catalogService: catalogService
                    )
                    return
                }
                continue
            case .secondary("m", _):
                selectedBackend = .mlx
            case .secondary("g", _):
                selectedBackend = .gguf
            case .secondary("s", _):
                guard let query = prompt("Model search query"), !query.isEmpty else {
                    continue
                }
                try await showSearchModelsMenu(
                    query: query,
                    service: service,
                    catalogService: catalogService
                )
                return
            case .secondary("a", _):
                try await showRecommendedModelsMenu(
                    service: service,
                    catalogService: catalogService
                )
                return
            case .secondary("o", let index):
                let modelIndex = index - 2
                guard models.indices.contains(modelIndex) else {
                    continue
                }
                let model = models[modelIndex]
                try await ModelOpenCommand.run(
                    identifier: model.id,
                    service: service,
                    catalogService: catalogService
                )
                continue
            default:
                return
            }
        }
    }

    private func starterMenuItems(
        for models: [RecommendedModel],
        backend: BackendKind
    ) -> [InteractiveListPicker.Item] {
        let backendItems = backendSwitcherItems(selectedBackend: backend)
        let modelItems = models.map { model in
            let features = featureBadgeText(ModelFeatureClassifier.features(for: model))
            return InteractiveListPicker.Item(
                title: "\(model.id)  \(features)",
                detail: "\(model.tier.displayName) | \(model.quantization) | \(model.memoryHint) | \(model.sizeHint) | \(model.repoID)"
            )
        }

        return backendItems + modelItems + [
            InteractiveListPicker.Item(
                title: "Search Other Models",
                detail: "Search the full MLX and GGUF catalog before installing"
            ),
            InteractiveListPicker.Item(
                title: "Browse All Presets",
                detail: "Open the full recommended preset list with backend switching"
            )
        ]
    }

    private func starterMenuTitle(
        header: String?,
        title: String,
        backend: BackendKind
    ) -> String {
        let menuTitle = "\(title) [\(backend.rawValue.uppercased())]"
        guard let header, !header.isEmpty else {
            return menuTitle
        }
        return header + "\n\n" + menuTitle
    }

    private func starterMenuSubtitle(
        base: String,
        backend: BackendKind,
        isEmpty: Bool
    ) -> String {
        let toggleHint = backend == .mlx
            ? "Showing MLX starters. Select MLX or GGUF at the top to switch backends."
            : "Showing GGUF starters. Select MLX or GGUF at the top to switch backends."
        if isEmpty {
            return base + " " + toggleHint + " Press s to search the full catalog."
        }
        return base + " " + toggleHint + " Press s to search the full catalog or a for all presets."
    }

    private func recommendedMenuItems(
        for models: [RecommendedModel],
        backend: BackendKind
    ) -> [InteractiveListPicker.Item] {
        let backendItems = backendSwitcherItems(selectedBackend: backend)
        guard !models.isEmpty else {
            return backendItems + [
                InteractiveListPicker.Item(
                    title: "No \(backend.rawValue.uppercased()) presets yet",
                    detail: "Select MLX or GGUF above to switch preset groups."
                )
            ]
        }

        return backendItems + models.map { model in
            let features = featureBadgeText(ModelFeatureClassifier.features(for: model))
            return InteractiveListPicker.Item(
                title: "\(model.id)  \(features)",
                detail: "\(model.tier.displayName) | \(model.quantization) | \(model.memoryHint) | \(model.sizeHint) | \(model.repoID)"
            )
        }
    }

    private func backendSwitcherItems(selectedBackend: BackendKind) -> [InteractiveListPicker.Item] {
        [
            InteractiveListPicker.Item(
                title: selectedBackend == .mlx ? "[x] MLX Presets" : "[ ] MLX Presets",
                detail: selectedBackend == .mlx
                    ? "Active backend for this list"
                    : "Switch to MLX preset recommendations"
            ),
            InteractiveListPicker.Item(
                title: selectedBackend == .gguf ? "[x] GGUF Presets" : "[ ] GGUF Presets",
                detail: selectedBackend == .gguf
                    ? "Active backend for this list"
                    : "Switch to GGUF llama.cpp recommendations"
            )
        ]
    }

    private func recommendedMenuSubtitle(for backend: BackendKind, isEmpty: Bool) -> String {
        let base = backend == .mlx
            ? "Showing MLX presets. Select MLX or GGUF at the top to switch backends."
            : "Showing GGUF presets. Select MLX or GGUF at the top to switch backends."
        if isEmpty {
            return base + " No presets are available in this backend yet."
        }
        return base + " Enter installs the selected model. Press s to search the full catalog or o to open the model page."
    }

    private func pickChatModel(
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws -> String? {
        let installs = try service.list()
        guard !installs.isEmpty else {
            try await showStarterModelsMenu(
                service: service,
                catalogService: catalogService,
                title: "Chat Needs A Local Model",
                subtitle: "Pick one supported starter model to install first, or press a to browse the full supported list."
            )
            return nil
        }

        let chatValidator = ChatModelValidator()
        let picker = InteractiveListPicker()
        let items = installs.map { install in
            let features = featureBadgeText(ModelFeatureClassifier.features(for: install))
            return InteractiveListPicker.Item(
                title: "\(install.id)  \(features)",
                detail: "\(install.spec.backend.rawValue) | \(ByteFormatting.string(for: install.sizeBytes)) | \(install.installPath)"
            )
        }

        while true {
            switch picker.pick(
                title: "Choose Chat Model",
                subtitle: "Enter starts chat with the selected model. Press o to open its model page or d to delete it. Compatibility is checked after selection.",
                items: items,
                primaryHint: "Enter start chat",
                secondaryHints: ["o open page", "d delete"],
                secondaryKeys: ["o", "d"]
            ) {
            case .selected(let index):
                let install = installs[index]
                printBusy("Checking \(install.id) runtime…")
                if let incompatibility = chatValidator.incompatibilityReason(for: install) {
                    print("Model \(install.id) is not chat-compatible with the current \(install.spec.backend.rawValue.uppercased()) runtime: \(incompatibility)")
                    pauseForMenu()
                    return nil
                }
                return install.id
            case .secondary("o", let index):
                try await ModelOpenCommand.run(
                    identifier: installs[index].id,
                    service: service,
                    catalogService: catalogService
                )
                continue
            case .secondary("d", let index):
                let install = installs[index]
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
        let chatValidator = ChatModelValidator()

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
                continue
            case .secondary("c", let index):
                let install = installs[index]
                printBusy("Checking \(install.id) runtime…")
                if let incompatibility = chatValidator.incompatibilityReason(for: install) {
                    print("Model \(install.id) is not chat-compatible with the current \(install.spec.backend.rawValue.uppercased()) runtime: \(incompatibility)")
                    pauseForMenu()
                    continue
                }
                guard let launchSettings = chooseChatLaunchSettings() else {
                    continue
                }
                printBusy("Opening chat with \(install.id)…")
                try await handleChat(
                    arguments: ["--model", install.id, "--cache-mode", launchSettings.cacheMode.rawValue, "--intent", launchSettings.intent.rawValue, "--autosave", launchSettings.autosaveEnabled ? "on" : "off"],
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

    private func showCachesMenu(cacheStore: CacheStore) async throws {
        let artifacts = try cacheStore.listArtifacts()
        guard !artifacts.isEmpty else {
            print("No cache artifacts.")
            pauseForMenu()
            return
        }

        let items = artifacts.map { artifact in
            InteractiveListPicker.Item(
                title: "\(CommandSupport.shortID(artifact.id))  \(artifact.manifest.modelID)",
                detail: "\(artifact.manifest.cacheMode.rawValue) | \(ByteFormatting.string(for: artifact.sizeBytes)) | \(artifact.manifest.sessionName)"
            )
        }

        let picker = InteractiveListPicker()
        switch picker.pick(
            title: "Saved Caches",
            subtitle: "Enter inspects the selected cache artifact.",
            items: items,
            primaryHint: "Enter inspect cache"
        ) {
        case .selected(let index):
            try CacheInspectCommand.run(
                arguments: ["inspect", artifacts[index].id.uuidString],
                store: cacheStore
            )
            pauseForMenu()
        default:
            return
        }
    }

    private func showSearchModelsMenu(
        query: String,
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws {
        printBusy("Searching models for \"\(query)\"…")
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
        while true {
            switch picker.pick(
                title: "Model Search: \(query)",
                subtitle: "Enter installs the selected model. Press o to open its model page.",
                items: items,
                primaryHint: "Enter install",
                secondaryHints: ["o open page"],
                secondaryKeys: ["o"]
            ) {
            case .selected(let index):
                let result = results[index]
                try await ModelInstallCommand.run(
                    identifier: result.modelSource.reference,
                    service: service,
                    catalogService: catalogService
                )
                pauseForMenu()
                return
            case .secondary("o", let index):
                let result = results[index]
                try await ModelOpenCommand.run(
                    identifier: result.modelSource.reference,
                    service: service,
                    catalogService: catalogService
                )
                continue
            default:
                return
            }
        }
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

    private func printBusy(_ message: String) {
        print("\u{001B}[2J\u{001B}[H\(message)")
        fflush(stdout)
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
