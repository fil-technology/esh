import Foundation
#if canImport(Darwin)
import Darwin
#endif
import EshCore

struct TUIApplication {
    private enum CommandOutcome {
        case notHandled
        case handled
        case exitChat
    }

    func run(
        sessionName: String,
        modelIdentifier: String? = nil,
        preferredCacheMode: CacheMode? = nil,
        preferredAutosaveEnabled: Bool? = nil,
        sessionStore: SessionStore
    ) async throws {
        let surface = TerminalSurface()
        var state = AppState(sessionName: sessionName)
        let root = PersistenceRoot.default()
        let modelStore = FileModelStore(root: root)
        let cacheStore = FileCacheStore(root: root)
        var session = try loadOrCreateSession(
            requestedName: sessionName,
            preferredModelID: modelIdentifier,
            preferredCacheMode: preferredCacheMode,
            preferredAutosaveEnabled: preferredAutosaveEnabled,
            sessionStore: sessionStore
        )
        var install = try CommandSupport.resolveInstall(
            identifier: modelIdentifier,
            modelStore: modelStore,
            preferredModelID: session.modelID
        )
        session.modelID = install.id
        let modelService = ModelService(
            store: modelStore,
            downloader: HuggingFaceModelDownloader(modelStore: modelStore)
        )
        let backend = MLXBackend()
        var runtime: any BackendRuntime = try await backend.loadRuntime(for: install)
        let chatService = ChatService()
        state = makeScreenState(
            for: session,
            installID: install.id,
            cacheMode: session.cacheMode?.rawValue ?? latestCacheMode(for: session, cacheStore: cacheStore) ?? "raw",
            autosaveEnabled: session.autosaveEnabled ?? false
        )
        state.statusText = "ready | /menu commands | /back launcher"
        surface.render(state: state)

        while let line = readInputLine(state: &state, surface: surface) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let commandOutcome = await handleCommand(
                trimmed,
                state: &state,
                session: &session,
                install: &install,
                runtime: &runtime,
                sessionStore: sessionStore,
                modelStore: modelStore,
                backend: backend,
                modelService: modelService,
                cacheStore: cacheStore,
                surface: surface
            )
            if commandOutcome == .handled {
                continue
            }
            if commandOutcome == .exitChat || trimmed == "/exit" {
                break
            }

            state.inputText = trimmed
            state.overlay = nil
            session.messages.append(Message(role: .user, text: trimmed))
            session.updatedAt = Date()
            state.transcriptItems.append(TranscriptItem(role: .user, text: trimmed))
            state.statusText = "streaming…"
            state.inputText = ""
            let stream = chatService.streamReply(runtime: runtime, session: session)
            let assistantID = UUID()
            state.streamingAssistantMessageID = assistantID
            state.transcriptItems.append(
                TranscriptItem(id: assistantID, role: .assistant, text: "", isStreaming: true)
            )
            surface.render(state: state)
            var reply = ""
            do {
                for try await chunk in stream {
                    reply += chunk
                    updateStreamingAssistant(
                        state: &state,
                        assistantID: assistantID,
                        text: reply,
                        isStreaming: true
                    )
                    state.statusText = streamingStatusText(for: reply)
                    surface.render(state: state)
                }
                session.messages.append(Message(role: .assistant, text: reply))
                session.updatedAt = Date()
                try autosaveIfNeeded(state: state, session: session, sessionStore: sessionStore)
                state.metrics = await runtime.metrics
                state.inputText = ""
                state.streamingAssistantMessageID = nil
                state.statusText = "ready | /menu commands | /back launcher"
                updateStreamingAssistant(
                    state: &state,
                    assistantID: assistantID,
                    text: reply,
                    isStreaming: false
                )
                surface.render(state: state)
            } catch {
                state.streamingAssistantMessageID = nil
                state.statusText = "generation failed"
                state.overlay = OverlayPanelState(
                    title: "Generation Failed",
                    lines: [error.localizedDescription]
                )
                if reply.isEmpty {
                    state.transcriptItems.removeAll { $0.id == assistantID }
                } else {
                    updateStreamingAssistant(
                        state: &state,
                        assistantID: assistantID,
                        text: reply,
                        isStreaming: false
                    )
                }
                surface.render(state: state)
            }
        }

        await runtime.unload()
    }

    private func handleCommand(
        _ command: String,
        state: inout AppState,
        session: inout ChatSession,
        install: inout ModelInstall,
        runtime: inout any BackendRuntime,
        sessionStore: SessionStore,
        modelStore: FileModelStore,
        backend: MLXBackend,
        modelService: ModelService,
        cacheStore: CacheStore,
        surface: TerminalSurface
    ) async -> CommandOutcome {
        guard command.hasPrefix("/") else { return .notHandled }

        if command.hasPrefix("/model inspect ") {
            let modelID = String(command.dropFirst("/model inspect ".count))
            showModelDetails(modelID: modelID, state: &state, modelService: modelService)
            state.inputText = ""
            surface.render(state: state)
            return .handled
        }

        if command.hasPrefix("/model open ") {
            let identifier = String(command.dropFirst("/model open ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try await ModelOpenCommand.run(
                    identifier: identifier,
                    service: modelService,
                    catalogService: ModelCatalogService(
                        localCatalog: LocalModelCatalog(store: modelStore),
                        huggingFaceCatalog: HuggingFaceModelCatalog(),
                        modelStore: modelStore
                    )
                )
                state.statusText = "opened model page"
            } catch {
                state.overlay = OverlayPanelState(title: "Open Model Page", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "model open failed"
            }
            state.inputText = ""
            surface.render(state: state)
            return .handled
        }

        if command.hasPrefix("/session show ") {
            let rawID = String(command.dropFirst("/session show ".count))
            showSessionDetails(rawID: rawID, state: &state, sessionStore: sessionStore)
            state.inputText = ""
            surface.render(state: state)
            return .handled
        }

        if command.hasPrefix("/cache inspect ") {
            let rawID = String(command.dropFirst("/cache inspect ".count))
            showCacheDetails(rawID: rawID, state: &state, cacheStore: cacheStore)
            state.inputText = ""
            surface.render(state: state)
            return .handled
        }

        if command.hasPrefix("/use-model ") {
            let identifier = String(command.dropFirst("/use-model ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let newInstall = try CommandSupport.resolveInstall(
                    identifier: identifier,
                    modelStore: modelStore,
                    preferredModelID: session.modelID
                )
                if let incompatibility = try backend.validateChatModel(for: newInstall) {
                    throw StoreError.invalidManifest(
                        "Model \(newInstall.id) is not chat-compatible with the current MLX runtime: \(incompatibility)"
                    )
                }
                if newInstall.id != install.id {
                    await runtime.unload()
                    runtime = try await backend.loadRuntime(for: newInstall)
                    install = newInstall
                }
                session.modelID = install.id
                session.backend = .mlx
                state.modelLabel = install.id
                state.statusText = "using model \(install.id)"
            } catch {
                state.overlay = OverlayPanelState(title: "Switch Model", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "model switch failed"
            }
            state.inputText = ""
            surface.render(state: state)
            return .handled
        }

        if command.hasPrefix("/search ") {
            let query = String(command.dropFirst("/search ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = query.lowercased()
            let matches = session.messages.enumerated().compactMap { index, message -> String? in
                guard message.text.lowercased().contains(lowered) else { return nil }
                return "#\(index + 1) \(message.role.rawValue): \(message.text)"
            }
            state.overlay = OverlayPanelState(
                title: "Search Results",
                lines: matches.isEmpty ? ["No matches for \(query)"] : matches
            )
            state.statusText = matches.isEmpty ? "no search matches" : "showing search results"
            state.inputText = ""
            surface.render(state: state)
            return .handled
        }

        switch command {
        case "/menu", "/help":
            state.overlay = OverlayPanelState(
                title: "Command Menu",
                lines: [
                    "/menu or /help  Show this command panel",
                    "/back           Return to the launcher",
                    "/close          Close the current panel",
                    "/save           Save the active chat session",
                    "/autosave on|off|toggle",
                    "/cache raw|turbo",
                    "/cache toggle",
                    "/settings       Show current chat settings",
                    "/new [name]",
                    "/switch <name-or-uuid>",
                    "/models         Show installed models",
                    "/use-model <id-or-repo>",
                    "/model current",
                    "/sessions       Show saved chat sessions",
                    "/caches         Show saved cache artifacts",
                    "/search <text>  Search the active session",
                    "/model open <id-or-alias>",
                    "/model inspect <id>",
                    "/session show <uuid>",
                    "/cache inspect <uuid>",
                    "/doctor         Show environment/runtime health",
                    "/exit           Leave chat"
                ]
            )
            state.statusText = "command menu open"
        case "/autosave":
            state.autosaveEnabled.toggle()
            session.autosaveEnabled = state.autosaveEnabled
            try? sessionStore.save(session: session)
            state.statusText = state.autosaveEnabled ? "autosave enabled" : "autosave disabled"
        case "/autosave on":
            state.autosaveEnabled = true
            session.autosaveEnabled = true
            try? sessionStore.save(session: session)
            state.statusText = "autosave enabled"
        case "/autosave off":
            state.autosaveEnabled = false
            session.autosaveEnabled = false
            try? sessionStore.save(session: session)
            state.statusText = "autosave disabled"
        case "/autosave toggle":
            state.autosaveEnabled.toggle()
            session.autosaveEnabled = state.autosaveEnabled
            try? sessionStore.save(session: session)
            state.statusText = state.autosaveEnabled ? "autosave enabled" : "autosave disabled"
        case "/cache raw":
            state.cacheMode = CacheMode.raw.rawValue
            session.cacheMode = .raw
            try? sessionStore.save(session: session)
            state.statusText = "cache mode raw"
        case "/cache turbo":
            state.cacheMode = CacheMode.turbo.rawValue
            session.cacheMode = .turbo
            try? sessionStore.save(session: session)
            state.statusText = "cache mode turbo"
        case "/cache toggle":
            let next: CacheMode = (session.cacheMode ?? .raw) == .raw ? .turbo : .raw
            session.cacheMode = next
            state.cacheMode = next.rawValue
            try? sessionStore.save(session: session)
            state.statusText = "cache mode \(next.rawValue)"
        case "/settings":
            state.overlay = OverlayPanelState(
                title: "Chat Settings",
                lines: [
                    "cache mode: \(session.cacheMode?.rawValue ?? state.cacheMode)",
                    "autosave: \((session.autosaveEnabled ?? state.autosaveEnabled) ? "on" : "off")",
                    "",
                    "Use /cache raw or /cache turbo",
                    "Use /autosave on or /autosave off"
                ]
            )
            state.statusText = "showing settings"
        case "/close":
            state.overlay = nil
            state.statusText = "ready | /menu commands | /back launcher"
        case "/back":
            return .exitChat
        case "/model current":
            state.overlay = OverlayPanelState(
                title: "Current Model",
                lines: [
                    "id: \(install.id)",
                    "source: \(install.spec.source.reference)",
                    "path: \(install.installPath)"
                ]
            )
            state.statusText = "showing current model"
        case "/save":
            do {
                session.updatedAt = Date()
                try sessionStore.save(session: session)
                state.transcriptItems.append(TranscriptItem(role: .system, text: "Session saved"))
                state.statusText = "session saved"
            } catch {
                state.transcriptItems.append(TranscriptItem(role: .system, text: "Save failed: \(error.localizedDescription)"))
                state.statusText = "save failed"
            }
        case let value where value.hasPrefix("/new"):
            do {
                try autosaveIfNeeded(state: state, session: session, sessionStore: sessionStore)
                let requestedName = value == "/new"
                    ? try nextSessionName(sessionStore: sessionStore)
                    : String(value.dropFirst("/new ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                session = ChatSession(name: requestedName.isEmpty ? try nextSessionName(sessionStore: sessionStore) : requestedName)
                session.modelID = install.id
                session.backend = .mlx
                session.cacheMode = state.cacheMode == CacheMode.turbo.rawValue ? .turbo : .raw
                session.autosaveEnabled = state.autosaveEnabled
                state = makeScreenState(
                    for: session,
                    installID: install.id,
                    cacheMode: session.cacheMode?.rawValue ?? "raw",
                    autosaveEnabled: state.autosaveEnabled
                )
                state.statusText = "new session"
            } catch {
                state.overlay = OverlayPanelState(title: "New Session", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "new session failed"
            }
        case let value where value.hasPrefix("/switch "):
            do {
                try autosaveIfNeeded(state: state, session: session, sessionStore: sessionStore)
                let identifier = String(value.dropFirst("/switch ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = try CommandSupport.resolveSession(identifier: identifier, sessionStore: sessionStore)
                session = resolved
                if session.modelID == nil {
                    session.modelID = install.id
                }
                if session.backend == nil {
                    session.backend = .mlx
                }
                install = try CommandSupport.resolveInstall(
                    identifier: nil,
                    modelStore: modelStore,
                    preferredModelID: session.modelID
                )
                await runtime.unload()
                runtime = try await backend.loadRuntime(for: install)
                state = makeScreenState(
                    for: session,
                    installID: install.id,
                    cacheMode: session.cacheMode?.rawValue ?? latestCacheMode(for: session, cacheStore: cacheStore) ?? "raw",
                    autosaveEnabled: session.autosaveEnabled ?? state.autosaveEnabled
                )
                state.statusText = "switched session"
            } catch {
                state.overlay = OverlayPanelState(title: "Switch Session", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "switch failed"
            }
        case "/models":
            do {
                let installs = try modelService.list()
                let lines = installs.isEmpty
                    ? ["No installed models."]
                    : installs.map {
                        let active = $0.id == install.id ? "*" : " "
                        return "\(active) \($0.id) | \($0.spec.source.reference) | \(ByteFormatting.string(for: $0.sizeBytes))"
                    }
                state.overlay = OverlayPanelState(title: "Installed Models", lines: lines)
                state.statusText = "showing installed models"
            } catch {
                state.overlay = OverlayPanelState(title: "Installed Models", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "model list failed"
            }
        case "/sessions":
            do {
                let sessions = try sessionStore.listSessions()
                let lines = sessions.isEmpty
                    ? ["No saved sessions."]
                    : sessions.map {
                        "\(sessionLabel(for: $0, activeSessionID: session.id)) | \($0.messages.count) messages"
                    }
                state.overlay = OverlayPanelState(title: "Saved Sessions", lines: lines)
                state.statusText = "showing sessions"
            } catch {
                state.overlay = OverlayPanelState(title: "Saved Sessions", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "session list failed"
            }
        case "/caches":
            do {
                let artifacts = try cacheStore.listArtifacts()
                let lines = artifacts.isEmpty
                    ? ["No cache artifacts."]
                    : artifacts.map {
                        "\(CommandSupport.shortID($0.id)) | \($0.manifest.sessionName) | \($0.manifest.modelID) | \($0.manifest.cacheMode.rawValue) | \(ByteFormatting.string(for: $0.sizeBytes))"
                    }
                state.overlay = OverlayPanelState(title: "Cache Artifacts", lines: lines)
                state.statusText = "showing caches"
            } catch {
                state.overlay = OverlayPanelState(title: "Cache Artifacts", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "cache list failed"
            }
        case "/doctor":
            do {
                let lines = try DoctorCommand.outputLines()
                state.overlay = OverlayPanelState(title: "Doctor", lines: lines)
                state.statusText = "doctor ok"
            } catch {
                state.overlay = OverlayPanelState(title: "Doctor", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "doctor failed"
            }
        case "/exit":
            return .exitChat
        default:
            state.overlay = OverlayPanelState(
                title: "Unknown Command",
                lines: [
                    "\(command)",
                    "Use /menu to see available in-chat commands."
                ]
            )
            state.statusText = "unknown command"
        }

        state.inputText = ""
        surface.render(state: state)
        return .handled
    }

    private func showModelDetails(
        modelID: String,
        state: inout AppState,
        modelService: ModelService
    ) {
        do {
            let manifest = try modelService.inspect(id: modelID)
            state.overlay = OverlayPanelState(
                title: "Model Details",
                lines: [
                    "id: \(manifest.install.id)",
                    "source: \(manifest.install.spec.source.kind.rawValue)",
                    "reference: \(manifest.install.spec.source.reference)",
                    "path: \(manifest.install.installPath)",
                    "backend: \(manifest.install.spec.backend.rawValue)",
                    "size: \(ByteFormatting.string(for: manifest.install.sizeBytes))",
                    "installed_at: \(manifest.install.installedAt)",
                    "created: \(manifest.createdAt)"
                ]
            )
            state.statusText = "showing model details"
        } catch {
            state.overlay = OverlayPanelState(title: "Model Details", lines: ["Error: \(error.localizedDescription)"])
            state.statusText = "model inspect failed"
        }
    }

    private func showSessionDetails(
        rawID: String,
        state: inout AppState,
        sessionStore: SessionStore
    ) {
        do {
            let session = try CommandSupport.resolveSession(identifier: rawID, sessionStore: sessionStore)
            var lines = [
                "id: \(session.id.uuidString)",
                "name: \(session.name)",
                "messages: \(session.messages.count)"
            ]
            lines.append(contentsOf: session.messages.map { "\($0.role.rawValue): \($0.text)" })
            state.overlay = OverlayPanelState(title: "Session Details", lines: lines)
            state.statusText = "showing session details"
        } catch {
            state.overlay = OverlayPanelState(title: "Session Details", lines: ["Error: \(error.localizedDescription)"])
            state.statusText = "session inspect failed"
        }
    }

    private func loadOrCreateSession(
        requestedName: String,
        preferredModelID: String?,
        preferredCacheMode: CacheMode?,
        preferredAutosaveEnabled: Bool?,
        sessionStore: SessionStore
    ) throws -> ChatSession {
        if let existing = try? CommandSupport.resolveSession(identifier: requestedName, sessionStore: sessionStore) {
            var session = existing
            session.modelID = session.modelID ?? preferredModelID
            session.backend = session.backend ?? .mlx
            session.cacheMode = preferredCacheMode ?? session.cacheMode
            session.autosaveEnabled = preferredAutosaveEnabled ?? session.autosaveEnabled
            return session
        }

        var session = ChatSession(name: requestedName)
        session.modelID = preferredModelID
        session.backend = .mlx
        session.cacheMode = preferredCacheMode ?? .raw
        session.autosaveEnabled = preferredAutosaveEnabled ?? false
        return session
    }

    private func makeScreenState(
        for session: ChatSession,
        installID: String,
        cacheMode: String = "raw",
        autosaveEnabled: Bool = false
    ) -> AppState {
        AppState(
            sessionName: session.name,
            backendLabel: "MLX",
            modelLabel: installID,
            cacheMode: cacheMode,
            metrics: .init(),
            statusText: "ready | /menu commands | /back launcher",
            inputText: "",
            transcriptItems: transcriptItems(from: session),
            streamingAssistantMessageID: nil,
            overlay: nil,
            autosaveEnabled: autosaveEnabled
        )
    }

    private func transcriptItems(from session: ChatSession) -> [TranscriptItem] {
        session.messages.map { message in
            TranscriptItem(
                role: message.role == .user ? .user : .assistant,
                text: message.text
            )
        }
    }

    private func autosaveIfNeeded(
        state: AppState,
        session: ChatSession,
        sessionStore: SessionStore
    ) throws {
        guard state.autosaveEnabled else { return }
        try sessionStore.save(session: session)
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

    private func sessionLabel(for session: ChatSession, activeSessionID: UUID) -> String {
        let shortID = String(session.id.uuidString.prefix(8))
        let activeMarker = session.id == activeSessionID ? "*" : " "
        return "\(activeMarker) \(session.name) [\(shortID)]"
    }

    private func latestCacheMode(for session: ChatSession, cacheStore: CacheStore) -> String? {
        let latest = try? cacheStore.listArtifacts()
            .filter { $0.manifest.sessionID == session.id }
            .max { lhs, rhs in
                lhs.manifest.createdAt < rhs.manifest.createdAt
            }
        return latest?.manifest.cacheMode.rawValue
    }

    private func showCacheDetails(
        rawID: String,
        state: inout AppState,
        cacheStore: CacheStore
    ) {
        guard let id = UUID(uuidString: rawID) else {
            state.overlay = OverlayPanelState(title: "Cache Details", lines: ["Invalid cache UUID: \(rawID)"])
            state.statusText = "cache inspect failed"
            return
        }
        do {
            let (artifact, _) = try cacheStore.loadArtifact(id: id)
            state.overlay = OverlayPanelState(
                title: "Cache Details",
                lines: [
                    "id: \(artifact.id.uuidString)",
                    "backend: \(artifact.manifest.backend.rawValue)",
                    "model: \(artifact.manifest.modelID)",
                    "mode: \(artifact.manifest.cacheMode.rawValue)",
                    "runtime: \(artifact.manifest.runtimeVersion)",
                    "format: \(artifact.manifest.cacheFormatVersion)",
                    "compressor: \(artifact.manifest.compressorVersion ?? "-")",
                    "size: \(ByteFormatting.string(for: artifact.sizeBytes))",
                    "created: \(artifact.manifest.createdAt)"
                ]
            )
            state.statusText = "showing cache details"
        } catch {
            state.overlay = OverlayPanelState(title: "Cache Details", lines: ["Error: \(error.localizedDescription)"])
            state.statusText = "cache inspect failed"
        }
    }

    private func updateStreamingAssistant(
        state: inout AppState,
        assistantID: UUID,
        text: String,
        isStreaming: Bool
    ) {
        guard let index = state.transcriptItems.firstIndex(where: { $0.id == assistantID }) else {
            return
        }
        state.transcriptItems[index].text = text
        state.transcriptItems[index].isStreaming = isStreaming
    }

    private func streamingStatusText(for text: String) -> String {
        let source = text.lowercased()
        if source.contains("<think>") && !source.contains("</think>") {
            return "reasoning…"
        }
        return "streaming…"
    }

    private func readInputLine(state: inout AppState, surface: TerminalSurface) -> String? {
        #if canImport(Darwin)
        guard isatty(STDIN_FILENO) != 0 else {
            fflush(stdout)
            return Swift.readLine()
        }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            fflush(stdout)
            return Swift.readLine()
        }

        var raw = original
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        raw.c_iflag &= ~UInt(IXON | ICRNL)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            fflush(stdout)
            return Swift.readLine()
        }

        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            state.inputText = ""
            surface.render(state: state)
        }

        state.inputText = ""
        surface.render(state: state)

        var buffer = ""
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count != 1 {
                return nil
            }

            switch byte {
            case 3:
                return "/exit"
            case 10, 13:
                return buffer
            case 8, 127:
                if !buffer.isEmpty {
                    buffer.removeLast()
                    state.inputText = buffer
                    surface.render(state: state)
                }
            default:
                guard let scalar = UnicodeScalar(Int(byte)),
                      !CharacterSet.controlCharacters.contains(scalar) else {
                    continue
                }
                buffer.append(Character(scalar))
                state.inputText = buffer
                surface.render(state: state)
            }
        }
        #else
        fflush(stdout)
        return Swift.readLine()
        #endif
    }
}
