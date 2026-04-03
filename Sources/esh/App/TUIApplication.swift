import Foundation
import EshCore

struct TUIApplication {
    func run(sessionName: String, sessionStore: SessionStore) async throws {
        let surface = TerminalSurface()
        var state = AppState(sessionName: sessionName)
        let root = PersistenceRoot.default()
        let modelStore = FileModelStore(root: root)
        let cacheStore = FileCacheStore(root: root)
        let installs = try modelStore.listInstalls()
        let install = try installs.first ?? {
            throw StoreError.notFound("No installed model found. Run `esh model install <hf-repo-id>` first.")
        }()
        var session = try loadOrCreateSession(
            requestedName: sessionName,
            installID: install.id,
            sessionStore: sessionStore
        )
        let modelService = ModelService(
            store: modelStore,
            downloader: HuggingFaceModelDownloader(modelStore: modelStore)
        )
        let backend = MLXBackend()
        let runtime = try await backend.loadRuntime(for: install)
        let chatService = ChatService()
        state = makeScreenState(for: session, installID: install.id)
        state.statusText = "ready | /menu for commands"
        surface.render(state: state)
        defer {
            Task { await runtime.unload() }
        }

        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if handleCommand(
                trimmed,
                state: &state,
                session: &session,
                installID: install.id,
                sessionStore: sessionStore,
                modelService: modelService,
                cacheStore: cacheStore,
                surface: surface
            ) {
                continue
            }
            if trimmed == "/exit" { break }

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
            for try await chunk in stream {
                reply += chunk
                updateStreamingAssistant(
                    state: &state,
                    assistantID: assistantID,
                    text: reply,
                    isStreaming: true
                )
                surface.render(state: state)
            }
            session.messages.append(Message(role: .assistant, text: reply))
            session.updatedAt = Date()
            try autosaveIfNeeded(state: state, session: session, sessionStore: sessionStore)
            state.metrics = await runtime.metrics
            state.inputText = ""
            state.streamingAssistantMessageID = nil
            state.statusText = "ready"
            updateStreamingAssistant(
                state: &state,
                assistantID: assistantID,
                text: reply,
                isStreaming: false
            )
            surface.render(state: state)
        }
    }

    private func handleCommand(
        _ command: String,
        state: inout AppState,
        session: inout ChatSession,
        installID: String,
        sessionStore: SessionStore,
        modelService: ModelService,
        cacheStore: CacheStore,
        surface: TerminalSurface
    ) -> Bool {
        guard command.hasPrefix("/") else { return false }

        if command.hasPrefix("/model inspect ") {
            let modelID = String(command.dropFirst("/model inspect ".count))
            showModelDetails(modelID: modelID, state: &state, modelService: modelService)
            state.inputText = ""
            surface.render(state: state)
            return true
        }

        if command.hasPrefix("/session show ") {
            let rawID = String(command.dropFirst("/session show ".count))
            showSessionDetails(rawID: rawID, state: &state, sessionStore: sessionStore)
            state.inputText = ""
            surface.render(state: state)
            return true
        }

        if command.hasPrefix("/cache inspect ") {
            let rawID = String(command.dropFirst("/cache inspect ".count))
            showCacheDetails(rawID: rawID, state: &state, cacheStore: cacheStore)
            state.inputText = ""
            surface.render(state: state)
            return true
        }

        switch command {
        case "/menu", "/help":
            state.overlay = OverlayPanelState(
                title: "Command Menu",
                lines: [
                    "/menu or /help  Show this command panel",
                    "/close          Close the current panel",
                    "/save           Save the active chat session",
                    "/autosave on|off|toggle",
                    "/new [name]",
                    "/switch <name-or-uuid>",
                    "/models         Show installed models",
                    "/sessions       Show saved chat sessions",
                    "/caches         Show saved cache artifacts",
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
            state.statusText = state.autosaveEnabled ? "autosave enabled" : "autosave disabled"
        case "/autosave on":
            state.autosaveEnabled = true
            state.statusText = "autosave enabled"
        case "/autosave off":
            state.autosaveEnabled = false
            state.statusText = "autosave disabled"
        case "/autosave toggle":
            state.autosaveEnabled.toggle()
            state.statusText = state.autosaveEnabled ? "autosave enabled" : "autosave disabled"
        case "/close":
            state.overlay = nil
            state.statusText = "ready | /menu for commands"
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
                session.modelID = installID
                session.backend = .mlx
                state = makeScreenState(for: session, installID: installID, autosaveEnabled: state.autosaveEnabled)
                state.statusText = "new session"
            } catch {
                state.overlay = OverlayPanelState(title: "New Session", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "new session failed"
            }
        case let value where value.hasPrefix("/switch "):
            do {
                try autosaveIfNeeded(state: state, session: session, sessionStore: sessionStore)
                let identifier = String(value.dropFirst("/switch ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = try resolveSession(identifier: identifier, sessionStore: sessionStore)
                session = resolved
                if session.modelID == nil {
                    session.modelID = installID
                }
                if session.backend == nil {
                    session.backend = .mlx
                }
                state = makeScreenState(for: session, installID: installID, autosaveEnabled: state.autosaveEnabled)
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
                    : installs.map { "\($0.id) | \(ByteFormatting.string(for: $0.sizeBytes)) | \($0.installPath)" }
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
                        "\($0.id.uuidString) | \($0.manifest.modelID) | \($0.manifest.cacheMode.rawValue) | \(ByteFormatting.string(for: $0.sizeBytes))"
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
            return false
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
        return command != "/exit"
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
            let session = try resolveSession(identifier: rawID, sessionStore: sessionStore)
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
        installID: String,
        sessionStore: SessionStore
    ) throws -> ChatSession {
        if let existing = try? resolveSession(identifier: requestedName, sessionStore: sessionStore) {
            var session = existing
            session.modelID = session.modelID ?? installID
            session.backend = session.backend ?? .mlx
            return session
        }

        var session = ChatSession(name: requestedName)
        session.modelID = installID
        session.backend = .mlx
        return session
    }

    private func resolveSession(
        identifier: String,
        sessionStore: SessionStore
    ) throws -> ChatSession {
        if let id = UUID(uuidString: identifier) {
            return try sessionStore.loadSession(id: id)
        }

        let sessions = try sessionStore.listSessions()
        if let exact = sessions.first(where: { $0.name == identifier }) {
            return exact
        }
        if let caseInsensitive = sessions.first(where: { $0.name.caseInsensitiveCompare(identifier) == .orderedSame }) {
            return caseInsensitive
        }

        throw StoreError.notFound("Session \(identifier) was not found.")
    }

    private func makeScreenState(
        for session: ChatSession,
        installID: String,
        autosaveEnabled: Bool = false
    ) -> AppState {
        AppState(
            sessionName: session.name,
            backendLabel: "MLX",
            modelLabel: installID,
            cacheMode: "raw",
            metrics: .init(),
            statusText: "ready | /menu for commands",
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

    private func readLine() -> String? {
        fflush(stdout)
        return Swift.readLine()
    }
}
