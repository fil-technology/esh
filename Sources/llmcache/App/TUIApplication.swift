import Foundation
import LLMCacheCore

struct TUIApplication {
    func run(sessionName: String, sessionStore: SessionStore) async throws {
        var state = AppState(sessionName: sessionName)
        var session = ChatSession(name: sessionName)
        let modelStore = FileModelStore(root: .default())
        let installs = try modelStore.listInstalls()
        let install = try installs.first ?? {
            throw StoreError.notFound("No installed model found. Run `llmcache model install <hf-repo-id>` first.")
        }()
        let backend = MLXBackend()
        let runtime = try await backend.loadRuntime(for: install)
        let chatService = ChatService()
        state.modelLabel = install.id
        session.modelID = install.id
        session.backend = .mlx
        render(state)
        defer {
            Task { await runtime.unload() }
        }

        while let line = readLine(prompt: "> ") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "/exit" { break }
            if trimmed == "/save" {
                session.updatedAt = Date()
                try sessionStore.save(session: session)
                state.transcript.append("system: session saved")
                render(state)
                continue
            }

            session.messages.append(Message(role: .user, text: trimmed))
            session.updatedAt = Date()
            state.transcript.append("you: \(trimmed)")
            let stream = chatService.streamReply(runtime: runtime, session: session)
            var reply = ""
            state.transcript.append("assistant: ")
            render(state)
            for try await chunk in stream {
                reply += chunk
                state.transcript[state.transcript.count - 1] = "assistant: \(reply)"
                render(state)
            }
            session.messages.append(Message(role: .assistant, text: reply))
            session.updatedAt = Date()
            state.metrics = await runtime.metrics
            render(state)
        }
    }

    private func render(_ state: AppState) {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        TranscriptView.render(lines: state.transcript)
        print("")
        FooterStatsView.render(state: state)
    }

    private func readLine(prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return Swift.readLine()
    }
}
