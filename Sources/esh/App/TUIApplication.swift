import Foundation
#if canImport(Darwin)
import Darwin
#endif
import EshCore

private enum TerminalInputAction: Sendable {
    case scrollUp
    case scrollDown
    case pageUp
    case pageDown
    case jumpToTop
    case jumpToBottom
}

private final class TerminalInputController: @unchecked Sendable {
    private let lock = NSLock()
    private var submittedLines: [String] = []
    private var pendingActions: [TerminalInputAction] = []
    private var buffer = ""
    private var stopRequested = false
    private var originalTermios: termios?
    private let queue = DispatchQueue(label: "esh.chat.input", qos: .userInitiated)

    func start() {
        #if canImport(Darwin)
        guard isatty(STDIN_FILENO) != 0 else { return }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return }
        var raw = original
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        raw.c_iflag &= ~UInt(IXON | ICRNL)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return }
        originalTermios = original

        queue.async { [self] in
            var suppressLF = false
            var suppressCR = false

            while !isStopped {
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 100)
                if ready <= 0 {
                    continue
                }

                var byte: UInt8 = 0
                guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else {
                    continue
                }

                switch byte {
                case 3:
                    submit("/exit")
                case 27:
                    if let action = readEscapeAction() {
                        enqueue(action)
                    }
                case 10:
                    if suppressLF {
                        suppressLF = false
                        continue
                    }
                    suppressCR = true
                    submitCurrentBuffer()
                case 13:
                    if suppressCR {
                        suppressCR = false
                        continue
                    }
                    suppressLF = true
                    submitCurrentBuffer()
                case 8, 127:
                    suppressLF = false
                    suppressCR = false
                    deleteBackward()
                default:
                    suppressLF = false
                    suppressCR = false
                    guard let scalar = UnicodeScalar(Int(byte)),
                          !CharacterSet.controlCharacters.contains(scalar) else {
                        continue
                    }
                    append(Character(scalar))
                }
            }
        }
        #endif
    }

    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()

        #if canImport(Darwin)
        if var original = originalTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        }
        #endif
    }

    func currentBuffer() -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func takeSubmittedLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let lines = submittedLines
        submittedLines.removeAll()
        return lines
    }

    func takeActions() -> [TerminalInputAction] {
        lock.lock()
        defer { lock.unlock() }
        let actions = pendingActions
        pendingActions.removeAll()
        return actions
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func append(_ character: Character) {
        lock.lock()
        buffer.append(character)
        lock.unlock()
    }

    private func deleteBackward() {
        lock.lock()
        if !buffer.isEmpty {
            buffer.removeLast()
        }
        lock.unlock()
    }

    private func submitCurrentBuffer() {
        lock.lock()
        let line = buffer
        buffer = ""
        if !line.isEmpty {
            submittedLines.append(line)
        }
        lock.unlock()
    }

    private func submit(_ line: String) {
        lock.lock()
        buffer = ""
        submittedLines.append(line)
        lock.unlock()
    }

    private func enqueue(_ action: TerminalInputAction) {
        lock.lock()
        pendingActions.append(action)
        lock.unlock()
    }

    private func readEscapeAction() -> TerminalInputAction? {
        #if canImport(Darwin)
        guard let first = readByte(timeoutMilliseconds: 5), first == 91 else {
            return nil
        }
        guard let second = readByte(timeoutMilliseconds: 5) else {
            return nil
        }

        switch second {
        case 65:
            return .scrollUp
        case 66:
            return .scrollDown
        case 70:
            return .jumpToBottom
        case 72:
            return .jumpToTop
        case 53:
            return readByte(timeoutMilliseconds: 5) == 126 ? .pageUp : nil
        case 54:
            return readByte(timeoutMilliseconds: 5) == 126 ? .pageDown : nil
        default:
            return nil
        }
        #else
        return nil
        #endif
    }

    private func readByte(timeoutMilliseconds: Int32) -> UInt8? {
        #if canImport(Darwin)
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, timeoutMilliseconds) > 0 else {
            return nil
        }
        var byte: UInt8 = 0
        guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else {
            return nil
        }
        return byte
        #else
        return nil
        #endif
    }
}

private final class StreamPump: @unchecked Sendable {
    private actor State {
        var pendingChunks: [String] = []
        var completionError: Error?
        var finished = false

        func append(_ chunk: String) {
            pendingChunks.append(chunk)
        }

        func markFinished() {
            finished = true
        }

        func markFailed(_ error: Error) {
            completionError = error
            finished = true
        }

        func takeChunks() -> [String] {
            let chunks = pendingChunks
            pendingChunks.removeAll()
            return chunks
        }

        func takeError() -> Error? {
            let error = completionError
            completionError = nil
            return error
        }

        func isFinished() -> Bool {
            finished && pendingChunks.isEmpty && completionError == nil
        }
    }

    private let state = State()

    func start(stream: AsyncThrowingStream<String, Error>) {
        Task {
            do {
                for try await chunk in stream {
                    await state.append(chunk)
                }
                await state.markFinished()
            } catch {
                await state.markFailed(error)
            }
        }
    }

    func takeChunks() async -> [String] {
        await state.takeChunks()
    }

    func takeError() async -> Error? {
        await state.takeError()
    }

    func isFinished() async -> Bool {
        await state.isFinished()
    }
}

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
        preferredIntent: SessionIntent? = nil,
        preferredAutosaveEnabled: Bool? = nil,
        routingEnabled: Bool = false,
        routingMode: String? = nil,
        sessionStore: SessionStore
    ) async throws {
        let surface = TerminalSurface()
        var state = AppState(sessionName: sessionName)
        let root = PersistenceRoot.default()
        let workspaceRootURL = WorkspaceContextLocator().workspaceRootURL(
            from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        )
        let modelStore = FileModelStore(root: root)
        let cacheStore = FileCacheStore(root: root)
        var session = try loadOrCreateSession(
            requestedName: sessionName,
            preferredModelID: modelIdentifier,
            preferredCacheMode: preferredCacheMode,
            preferredIntent: preferredIntent,
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
        let backendRegistry = InferenceBackendRegistry()
        let backend = backendRegistry.backend(for: install)
        var runtime: any BackendRuntime = try await backend.loadRuntime(for: install)
        let chatService = ChatService()
        let inputController = TerminalInputController()
        inputController.start()
        defer { inputController.stop() }
        state = makeScreenState(
            for: session,
            installID: install.id,
            backendLabel: runtime.backend.rawValue.uppercased(),
            cacheMode: session.cacheMode?.rawValue ?? latestCacheMode(for: session, cacheStore: cacheStore) ?? "raw",
            autosaveEnabled: session.autosaveEnabled ?? false
        )
        state.statusText = routingEnabled
            ? "ready | routing \(routingMode ?? "sequential") | /menu commands | /back launcher"
            : "ready | /menu commands | /back launcher"
        surface.render(state: state)
        var queuedPrompts: [String] = []

        while let line = try await nextInputLine(
            state: &state,
            surface: surface,
            inputController: inputController,
            queuedPrompts: &queuedPrompts
        ) {
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
                backendRegistry: backendRegistry,
                modelService: modelService,
                cacheStore: cacheStore,
                workspaceRootURL: workspaceRootURL,
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
            state.transcriptScrollOffset = 0
            session.messages.append(Message(role: .user, text: trimmed))
            session.updatedAt = Date()
            state.transcriptItems.append(TranscriptItem(role: .user, text: trimmed))
            let preparedSession = enrichedSessionIfNeeded(
                baseSession: session,
                latestUserText: trimmed,
                workspaceRootURL: workspaceRootURL
            )
            if routingEnabled {
                state.statusText = "routing…"
                state.inputText = ""
                let assistantID = UUID()
                state.streamingAssistantMessageID = assistantID
                state.transcriptItems.append(
                    TranscriptItem(id: assistantID, role: .assistant, text: "", isStreaming: true)
                )
                surface.render(state: state)

                do {
                    let routingResponse = try await routedReply(
                        preparedSession: preparedSession.session,
                        install: install,
                        routingMode: routingMode,
                        root: root,
                        workspaceRootURL: workspaceRootURL
                    )
                    let reply = routingResponse.outputText
                    session.messages.append(Message(role: .assistant, text: reply))
                    session.updatedAt = Date()
                    try autosaveIfNeeded(state: state, session: session, sessionStore: sessionStore)
                    state.metrics = routingResponse.metrics
                    state.inputText = inputController.currentBuffer()
                    state.streamingAssistantMessageID = nil
                    state.statusText = routedStatusText(response: routingResponse, queuedCount: queuedPrompts.count)
                    updateStreamingAssistant(
                        state: &state,
                        assistantID: assistantID,
                        text: reply,
                        isStreaming: false
                    )
                    surface.render(state: state)
                } catch {
                    state.streamingAssistantMessageID = nil
                    state.statusText = queuedPrompts.isEmpty
                        ? "routing failed"
                        : "routing failed | \(queuedPrompts.count) queued"
                    state.overlay = OverlayPanelState(
                        title: "Routing Failed",
                        lines: [error.localizedDescription]
                    )
                    state.transcriptItems.removeAll { $0.id == assistantID }
                    state.inputText = inputController.currentBuffer()
                    surface.render(state: state)
                }
                continue
            }
            state.statusText = preparedSession.usedContextBrief
                ? "planning with local context…"
                : (runtime.backend == .gguf ? "loading GGUF model / waiting for first token…" : "streaming…")
            state.inputText = ""
            let stream = chatService.streamReply(runtime: runtime, session: preparedSession.session)
            let pump = StreamPump()
            pump.start(stream: stream)
            let assistantID = UUID()
            state.streamingAssistantMessageID = assistantID
            state.transcriptItems.append(
                TranscriptItem(id: assistantID, role: .assistant, text: "", isStreaming: true)
            )
            surface.render(state: state)
            var reply = ""
            do {
                while true {
                    updateQueuedPrompts(
                        queuedPrompts: &queuedPrompts,
                        state: &state,
                        surface: surface,
                        inputController: inputController,
                        whileStreaming: true
                    )

                    let chunks = await pump.takeChunks()
                    if !chunks.isEmpty {
                        reply += chunks.joined()
                        updateStreamingAssistant(
                            state: &state,
                            assistantID: assistantID,
                            text: reply,
                            isStreaming: true
                        )
                        state.statusText = streamingStatusText(for: reply, queuedCount: queuedPrompts.count)
                        surface.render(state: state)
                    }

                    if let error = await pump.takeError() {
                        throw error
                    }

                    if await pump.isFinished() {
                        break
                    }

                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                session.messages.append(Message(role: .assistant, text: reply))
                session.updatedAt = Date()
                try autosaveIfNeeded(state: state, session: session, sessionStore: sessionStore)
                state.metrics = await runtime.metrics
                state.inputText = inputController.currentBuffer()
                state.streamingAssistantMessageID = nil
                state.statusText = queuedPrompts.isEmpty
                    ? "ready | /menu commands | /back launcher"
                    : "ready | \(queuedPrompts.count) queued"
                updateStreamingAssistant(
                    state: &state,
                    assistantID: assistantID,
                    text: reply,
                    isStreaming: false
                )
                surface.render(state: state)
            } catch {
                state.streamingAssistantMessageID = nil
                state.statusText = queuedPrompts.isEmpty
                    ? "generation failed"
                    : "generation failed | \(queuedPrompts.count) queued"
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
                state.inputText = inputController.currentBuffer()
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
        backendRegistry: InferenceBackendRegistry,
        modelService: ModelService,
        cacheStore: CacheStore,
        workspaceRootURL: URL,
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
                let newBackend = backendRegistry.backend(for: newInstall)
                if let incompatibility = ChatModelValidator(backendRegistry: backendRegistry).incompatibilityReason(for: newInstall) {
                    throw StoreError.invalidManifest(
                        "Model \(newInstall.id) is not chat-compatible with the current \(newInstall.spec.backend.rawValue.uppercased()) runtime: \(incompatibility)"
                    )
                }
                if newInstall.id != install.id {
                    await runtime.unload()
                    runtime = try await newBackend.loadRuntime(for: newInstall)
                    install = newInstall
                }
                session.modelID = install.id
                session.backend = install.spec.backend
                state.modelLabel = install.id
                state.backendLabel = runtime.backend.rawValue.uppercased()
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

        if command.hasPrefix("/plan ") {
            let task = String(command.dropFirst("/plan ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let lines = try contextPlanLines(task: task, workspaceRootURL: workspaceRootURL)
                state.overlay = OverlayPanelState(title: "Context Plan", lines: lines)
                state.statusText = "context plan ready"
            } catch {
                state.overlay = OverlayPanelState(title: "Context Plan", lines: ["Error: \(error.localizedDescription)"])
                state.statusText = "context plan failed"
            }
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
                    "/cache raw|turbo|triattention|auto",
                    "/cache toggle",
                    "/intent chat|code|documentqa|agentrun|multimodal",
                    "/settings       Show current chat settings",
                    "/new [name]",
                    "/switch <name-or-uuid>",
                    "/models         Show installed models",
                    "/use-model <id-or-repo>",
                    "/model current",
                    "/sessions       Show saved chat sessions",
                    "/caches         Show saved cache artifacts",
                    "/search <text>  Search the active session",
                    "/plan <task>    Build a local context brief",
                    "↑/↓             Scroll transcript by line",
                    "PgUp/PgDn       Scroll transcript by page",
                    "Home/End        Jump to top or bottom",
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
        case "/cache triattention":
            state.cacheMode = CacheMode.triattention.rawValue
            session.cacheMode = .triattention
            try? sessionStore.save(session: session)
            state.statusText = "cache mode triattention"
        case "/cache auto":
            state.cacheMode = CacheMode.automatic.rawValue
            session.cacheMode = .automatic
            try? sessionStore.save(session: session)
            state.statusText = "cache mode auto"
        case "/cache toggle":
            let cycle: [CacheMode] = [.raw, .turbo, .triattention, .automatic]
            let current = session.cacheMode ?? .automatic
            let nextIndex = ((cycle.firstIndex(of: current) ?? 0) + 1) % cycle.count
            let next = cycle[nextIndex]
            session.cacheMode = next
            state.cacheMode = next.rawValue
            try? sessionStore.save(session: session)
            state.statusText = "cache mode \(next.rawValue)"
        case "/intent chat":
            session.intent = .chat
            try? sessionStore.save(session: session)
            state.statusText = "intent chat"
        case "/intent code":
            session.intent = .code
            try? sessionStore.save(session: session)
            state.statusText = "intent code"
        case "/intent documentqa":
            session.intent = .documentQA
            try? sessionStore.save(session: session)
            state.statusText = "intent documentqa"
        case "/intent agentrun":
            session.intent = .agentRun
            try? sessionStore.save(session: session)
            state.statusText = "intent agentrun"
        case "/intent multimodal":
            session.intent = .multimodal
            try? sessionStore.save(session: session)
            state.statusText = "intent multimodal"
        case "/settings":
            state.overlay = OverlayPanelState(
                title: "Chat Settings",
                lines: [
                    "cache mode: \(session.cacheMode?.rawValue ?? state.cacheMode)",
                    "intent: \(session.intent?.rawValue ?? SessionIntent.chat.rawValue)",
                    "autosave: \((session.autosaveEnabled ?? state.autosaveEnabled) ? "on" : "off")",
                    "",
                    "Use /cache raw, /cache turbo, /cache triattention, or /cache auto",
                    "Use /intent chat, /intent code, /intent documentqa, /intent agentrun, or /intent multimodal",
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
                    install.spec.variant.map { "variant: \($0)" },
                    "path: \(install.installPath)"
                ].compactMap { $0 }
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
                session.backend = install.spec.backend
                session.cacheMode = CacheMode(rawValue: state.cacheMode) ?? .automatic
                session.intent = session.intent ?? .chat
                session.autosaveEnabled = state.autosaveEnabled
                state = makeScreenState(
                    for: session,
                    installID: install.id,
                    backendLabel: runtime.backend.rawValue.uppercased(),
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
                    session.backend = install.spec.backend
                }
                if session.intent == nil {
                    session.intent = .chat
                }
                install = try CommandSupport.resolveInstall(
                    identifier: nil,
                    modelStore: modelStore,
                    preferredModelID: session.modelID
                )
                await runtime.unload()
                runtime = try await backendRegistry.backend(for: install).loadRuntime(for: install)
                state = makeScreenState(
                    for: session,
                    installID: install.id,
                    backendLabel: runtime.backend.rawValue.uppercased(),
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
                    manifest.install.spec.variant.map { "variant: \($0)" },
                    "path: \(manifest.install.installPath)",
                    "backend: \(manifest.install.spec.backend.rawValue)",
                    "size: \(ByteFormatting.string(for: manifest.install.sizeBytes))",
                    "installed_at: \(manifest.install.installedAt)",
                    "created: \(manifest.createdAt)"
                ].compactMap { $0 }
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
        preferredIntent: SessionIntent?,
        preferredAutosaveEnabled: Bool?,
        sessionStore: SessionStore
    ) throws -> ChatSession {
        if let existing = try? CommandSupport.resolveSession(identifier: requestedName, sessionStore: sessionStore) {
            var session = existing
            session.modelID = session.modelID ?? preferredModelID
            session.backend = session.backend ?? .mlx
            session.cacheMode = preferredCacheMode ?? session.cacheMode
            session.intent = preferredIntent ?? session.intent
            session.autosaveEnabled = preferredAutosaveEnabled ?? session.autosaveEnabled
            return session
        }

        var session = ChatSession(name: requestedName)
        session.modelID = preferredModelID
        session.backend = .mlx
        session.cacheMode = preferredCacheMode ?? .automatic
        session.intent = preferredIntent ?? .chat
        session.autosaveEnabled = preferredAutosaveEnabled ?? false
        return session
    }

    private func makeScreenState(
        for session: ChatSession,
        installID: String,
        backendLabel: String,
        cacheMode: String = "raw",
        autosaveEnabled: Bool = false
    ) -> AppState {
        AppState(
            sessionName: session.name,
            backendLabel: backendLabel,
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

    private func routedReply(
        preparedSession: ChatSession,
        install: ModelInstall,
        routingMode: String?,
        root: PersistenceRoot,
        workspaceRootURL: URL
    ) async throws -> ExternalInferenceResponse {
        var routing = (try? RoutingConfigurationStore(root: root).load()) ?? RoutingConfiguration()
        routing.enabled = true
        if let routingMode {
            guard let parsed = RoutingMode(rawValue: routingMode.lowercased()) else {
                throw StoreError.invalidManifest("Invalid routing mode: \(routingMode)")
            }
            routing.mode = parsed
            routing.enabled = parsed != .disabled
        } else if routing.mode == .disabled {
            routing.mode = .sequential
        }
        routing.mainModel = routing.mainModel ?? install.id

        let request = ExternalInferenceRequest(
            model: install.id,
            cacheMode: preparedSession.cacheMode,
            intent: preparedSession.intent,
            messages: preparedSession.messages.map {
                ExternalInferenceMessage(role: $0.role, text: $0.text)
            },
            generation: GenerationConfig(temperature: routing.mainTemperature),
            routing: routing
        )
        let service = ExternalInferenceService(
            modelStore: FileModelStore(root: root),
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root),
            workspaceRootURL: workspaceRootURL
        )
        return try await service.infer(request: request)
    }

    private func routedStatusText(response: ExternalInferenceResponse, queuedCount: Int) -> String {
        var parts = ["routed"]
        if let selected = response.routing?.selectedModel {
            parts.append(selected)
        }
        if let action = response.routing?.decision?.action.rawValue {
            parts.append(action)
        }
        if queuedCount > 0 {
            parts.append("\(queuedCount) queued")
        }
        return parts.joined(separator: " | ")
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

    private func contextPlanLines(task: String, workspaceRootURL: URL) throws -> [String] {
        let index = try ContextStore().load(workspaceRootURL: workspaceRootURL)
        let resolution = try ContextPackageService().resolveBrief(
            task: task,
            index: index,
            workspaceRootURL: workspaceRootURL,
            limit: 4,
            snippetCount: 2
        )
        let brief = resolution.brief

        var lines = [
            "task: \(brief.task)",
            "summary: \(brief.summary)",
            "context package: \(resolution.package.id.uuidString)",
            "reused: \(resolution.reused ? "yes" : "no")"
        ]

        if let runSummary = brief.runSummary {
            lines.append("run status: \(runSummary.status)")
            if runSummary.hypotheses.isEmpty == false {
                lines.append("hypotheses: \(runSummary.hypotheses.prefix(2).joined(separator: " | "))")
            }
            if runSummary.findings.isEmpty == false {
                lines.append("findings: \(runSummary.findings.prefix(2).joined(separator: " | "))")
            }
        }

        if brief.rankedResults.isEmpty == false {
            lines.append("top files:")
            lines.append(contentsOf: brief.rankedResults.prefix(4).map {
                "\($0.filePath) [\(String(format: "%.1f", $0.score))] \($0.reasons.prefix(2).joined(separator: ", "))"
            })
        }

        if brief.openQuestions.isEmpty == false {
            lines.append("open questions:")
            lines.append(contentsOf: brief.openQuestions.prefix(3))
        }

        if brief.suggestedNextSteps.isEmpty == false {
            lines.append("next steps:")
            lines.append(contentsOf: brief.suggestedNextSteps.prefix(4))
        }

        return lines
    }

    private func enrichedSessionIfNeeded(
        baseSession: ChatSession,
        latestUserText: String,
        workspaceRootURL: URL
    ) -> (session: ChatSession, usedContextBrief: Bool) {
        guard let intent = baseSession.intent,
              [.code, .documentQA, .agentRun].contains(intent) else {
            return (baseSession, false)
        }

        guard let index = try? ContextStore().load(workspaceRootURL: workspaceRootURL),
              let resolution = try? ContextPackageService().resolveBrief(
                task: latestUserText,
                index: index,
                workspaceRootURL: workspaceRootURL,
                limit: 4,
                snippetCount: 2,
                modelID: baseSession.modelID,
                intent: intent,
                cacheMode: baseSession.cacheMode
              ) else {
            return (baseSession, false)
        }

        let brief = resolution.brief
        guard
              brief.rankedResults.isEmpty == false || brief.snippets.isEmpty == false else {
            return (baseSession, false)
        }

        var session = baseSession
        guard let lastIndex = session.messages.indices.last else {
            return (baseSession, false)
        }
        session.messages[lastIndex].text = ContextPlanningService().augmentedPrompt(
            userPrompt: latestUserText,
            brief: brief
        )
        return (session, true)
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

    private func streamingStatusText(for text: String, queuedCount: Int = 0) -> String {
        let source = text.lowercased()
        let base: String
        if source.isEmpty {
            base = "loading model / waiting for first token…"
        } else if source.contains("<think>") && !source.contains("</think>") {
            base = "reasoning…"
        } else {
            base = "streaming…"
        }
        if queuedCount > 0 {
            return "\(base) | \(queuedCount) queued"
        }
        return base
    }

    private func updateQueuedPrompts(
        queuedPrompts: inout [String],
        state: inout AppState,
        surface: TerminalSurface,
        inputController: TerminalInputController,
        whileStreaming: Bool
    ) {
        let newLines = inputController.takeSubmittedLines()
        let actions = inputController.takeActions()
        if !newLines.isEmpty {
            queuedPrompts.append(contentsOf: newLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }

        let scrolled = applyInputActions(actions, state: &state, surface: surface)

        let buffer = inputController.currentBuffer()
        let shouldRender = state.inputText != buffer || !newLines.isEmpty || scrolled
        state.inputText = buffer
        if whileStreaming {
            let currentAssistant = state.transcriptItems.last(where: { $0.role == .assistant })?.text ?? ""
            state.statusText = streamingStatusText(for: currentAssistant, queuedCount: queuedPrompts.count)
        }
        if shouldRender {
            surface.render(state: state)
        }
    }

    private func nextInputLine(
        state: inout AppState,
        surface: TerminalSurface,
        inputController: TerminalInputController,
        queuedPrompts: inout [String]
    ) async throws -> String? {
        while true {
            if !queuedPrompts.isEmpty {
                return queuedPrompts.removeFirst()
            }

            let actions = inputController.takeActions()
            if applyInputActions(actions, state: &state, surface: surface) {
                continue
            }

            let newLines = inputController.takeSubmittedLines()
            if let first = newLines.first {
                if newLines.count > 1 {
                    queuedPrompts.append(contentsOf: newLines.dropFirst())
                }
                return first
            }

            let buffer = inputController.currentBuffer()
            if state.inputText != buffer {
                state.inputText = buffer
                surface.render(state: state)
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @discardableResult
    private func applyInputActions(
        _ actions: [TerminalInputAction],
        state: inout AppState,
        surface: TerminalSurface
    ) -> Bool {
        guard !actions.isEmpty else { return false }
        let maxOffset = surface.maxTranscriptScrollOffset(state: state)
        let pageSize = 10
        var offset = min(max(state.transcriptScrollOffset, 0), maxOffset)

        for action in actions {
            switch action {
            case .scrollUp:
                offset = min(offset + 1, maxOffset)
            case .scrollDown:
                offset = max(offset - 1, 0)
            case .pageUp:
                offset = min(offset + pageSize, maxOffset)
            case .pageDown:
                offset = max(offset - pageSize, 0)
            case .jumpToTop:
                offset = maxOffset
            case .jumpToBottom:
                offset = 0
            }
        }

        guard offset != state.transcriptScrollOffset else { return false }
        state.transcriptScrollOffset = offset
        state.statusText = offset == 0
            ? "ready | /menu commands | /back launcher"
            : "scrolling transcript | ↑/↓ line • PgUp/PgDn page • Home/End jump"
        surface.render(state: state)
        return true
    }
}
