import Foundation
import EshCore

enum BenchmarkCommand {
    static func run(arguments: [String]) async throws {
        if arguments.first == "history" {
            try showHistory()
            return
        }

        let sessionIdentifier = try CommandSupport.requiredValue(flag: "--session", in: arguments)
        let modelIdentifier = CommandSupport.optionalValue(flag: "--model", in: arguments)
        let followupMessage = CommandSupport.optionalValue(flag: "--message", in: arguments)
            ?? "Continue with one short sentence."

        let root = PersistenceRoot.default()
        let sessionStore = FileSessionStore(root: root)
        let modelStore = FileModelStore(root: root)
        let cacheStore = FileCacheStore(root: root)
        let benchmarkStore = FileBenchmarkStore(root: root)

        let session = try CommandSupport.resolveSession(identifier: sessionIdentifier, sessionStore: sessionStore)
        let install = try CommandSupport.resolveInstall(
            identifier: modelIdentifier,
            modelStore: modelStore,
            preferredModelID: session.modelID
        )
        guard install.spec.backend == .mlx else {
            throw StoreError.invalidManifest("Benchmark currently supports MLX models only. GGUF cache benchmarking is not implemented yet.")
        }

        let raw = try await measure(
            session: session,
            install: install,
            cacheStore: cacheStore,
            compressor: PassthroughCompressor(),
            followupMessage: followupMessage
        )

        let turbo = try await measure(
            session: session,
            install: install,
            cacheStore: cacheStore,
            compressor: TurboQuantCompressor(),
            followupMessage: followupMessage
        )

        let record = BenchmarkRecord(
            sessionID: session.id,
            sessionName: session.name,
            modelID: install.id,
            followupMessage: followupMessage,
            raw: raw,
            turbo: turbo
        )
        try benchmarkStore.save(record)

        print("benchmark: \(record.id.uuidString)")
        print("session: \(record.sessionName) [\(CommandSupport.shortID(record.sessionID))]")
        print("model: \(record.modelID)")
        print("followup: \(record.followupMessage)")
        print("raw: build \(format(raw.buildMilliseconds)) ms | load \(format(raw.loadMilliseconds)) ms | size \(ByteFormatting.string(for: raw.artifactBytes)) | ttft \(format(raw.metrics.ttftMilliseconds)) ms | tok/s \(format(raw.metrics.tokensPerSecond))")
        print("turbo: build \(format(turbo.buildMilliseconds)) ms | load \(format(turbo.loadMilliseconds)) ms | size \(ByteFormatting.string(for: turbo.artifactBytes)) | ttft \(format(turbo.metrics.ttftMilliseconds)) ms | tok/s \(format(turbo.metrics.tokensPerSecond))")
        if turbo.artifactBytes > 0 {
            let ratio = Double(raw.artifactBytes) / Double(turbo.artifactBytes)
            print("turbo_ratio: \(String(format: "%.2f", ratio))x")
        }
    }

    private static func measure(
        session: ChatSession,
        install: ModelInstall,
        cacheStore: FileCacheStore,
        compressor: CacheCompressor,
        followupMessage: String
    ) async throws -> BenchmarkMeasurement {
        let backend = MLXBackend()
        let codec = MLXCacheSnapshotCodec()
        let cacheService = CacheService(cacheStore: cacheStore)
        let checker = backend.makeCompatibilityChecker(for: install)

        let buildRuntime = try await backend.loadRuntime(for: install)
        let buildStopwatch = Stopwatch()
        let buildResult = try await cacheService.buildArtifact(
            runtime: buildRuntime,
            session: session,
            install: install,
            codec: codec,
            compressor: compressor
        )
        let buildMilliseconds = buildStopwatch.elapsedMilliseconds()
        await buildRuntime.unload()

        let loadRuntime = try await backend.loadRuntime(for: install)
        let loadStopwatch = Stopwatch()
        _ = try await cacheService.loadArtifactForRuntime(
            id: buildResult.artifact.id,
            runtime: loadRuntime,
            install: install,
            codec: codec,
            compressor: compressor,
            checker: checker
        )
        let loadMilliseconds = loadStopwatch.elapsedMilliseconds()

        var benchmarkSession = session
        benchmarkSession.modelID = install.id
        benchmarkSession.backend = .mlx
        benchmarkSession.messages.append(Message(role: .user, text: followupMessage))

        let stream = ChatService().streamReply(
            runtime: loadRuntime,
            session: benchmarkSession,
            config: GenerationConfig(maxTokens: 128, temperature: 0.2)
        )
        var response = ""
        for try await chunk in stream {
            response += chunk
        }
        let metrics = await loadRuntime.metrics
        await loadRuntime.unload()

        return BenchmarkMeasurement(
            artifactID: buildResult.artifact.id,
            cacheMode: compressor.mode,
            buildMilliseconds: buildMilliseconds,
            loadMilliseconds: loadMilliseconds,
            artifactBytes: buildResult.artifact.sizeBytes,
            snapshotBytes: buildResult.artifact.snapshotSizeBytes,
            metrics: metrics,
            responsePreview: String(response.prefix(160))
        )
    }

    private static func showHistory() throws {
        let records = try FileBenchmarkStore(root: .default()).list()
        if records.isEmpty {
            print("No benchmark runs.")
            return
        }

        for record in records {
            let ratio = record.turbo.artifactBytes > 0
                ? Double(record.raw.artifactBytes) / Double(record.turbo.artifactBytes)
                : 1
            print("\(record.id.uuidString)\t\(record.sessionName)\t\(record.modelID)\traw \(ByteFormatting.string(for: record.raw.artifactBytes))\tturbo \(ByteFormatting.string(for: record.turbo.artifactBytes))\t\(String(format: "%.2f", ratio))x")
        }
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f", value)
    }
}
