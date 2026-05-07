import Foundation
import EshCore

enum InferCommand {
    static func run(arguments: [String], root: PersistenceRoot) async throws {
        let request = try resolveRequest(arguments: arguments)
        let debugRouting = arguments.contains("--debug-routing")
        let service = ExternalInferenceService(
            modelStore: FileModelStore(root: root),
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root)
        )
        let response = try await service.infer(request: request)
        if debugRouting, let routing = response.routing {
            printRoutingDebug(routing)
        }
        let data = try JSONCoding.encoder.encode(response)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func resolveRequest(arguments: [String]) throws -> ExternalInferenceRequest {
        if let inputPath = CommandSupport.optionalValue(flag: "--input", in: arguments) {
            let data = try readInput(path: inputPath)
            return try JSONCoding.decoder.decode(ExternalInferenceRequest.self, from: data)
        }

        let knownFlags: Set<String> = [
            "--model",
            "--message",
            "--system",
            "--artifact",
            "--max-tokens",
            "--temperature",
            "--top-p",
            "--top-k",
            "--min-p",
            "--repetition-penalty",
            "--seed",
            "--thinking-budget",
            "--thinking-start-token",
            "--thinking-end-token",
            "--kv-bits",
            "--kv-quant-scheme",
            "--kv-group-size",
            "--quantized-kv-start",
            "--cache-mode",
            "--intent",
            "--session-name",
            "--routing-mode",
            "--router",
            "--coding-model",
            "--fallback-model"
        ]
        let positional = CommandSupport.positionalArguments(in: arguments, knownFlags: knownFlags)
            .filter { !$0.hasPrefix("--") }
        let positionalMessage = positional.first

        let message = CommandSupport.optionalValue(flag: "--message", in: arguments) ?? positionalMessage
        guard let message, message.isEmpty == false else {
            throw StoreError.invalidManifest(
                "Usage: esh infer --input <path-or-> | esh infer --model <id-or-repo> --message <text> [--system <text>] [--artifact <uuid>] [--max-tokens N] [--temperature T] [--top-p P] [--top-k K] [--min-p P] [--repetition-penalty R] [--seed N] [--enable-thinking] [--thinking-budget N] [--kv-bits N] [--kv-quant-scheme uniform|turboquant] [--kv-group-size N] [--quantized-kv-start N] [--cache-mode raw|turbo|triattention|auto] [--intent chat|code|documentqa|agentrun|multimodal] [--session-name <name>]"
            )
        }

        let systemPrompt = CommandSupport.optionalValue(flag: "--system", in: arguments)
        let model = CommandSupport.optionalValue(flag: "--model", in: arguments)
        let artifactValue = CommandSupport.optionalValue(flag: "--artifact", in: arguments)
        let cacheModeValue = CommandSupport.optionalValue(flag: "--cache-mode", in: arguments)
        let intentValue = CommandSupport.optionalValue(flag: "--intent", in: arguments)
        let sessionName = CommandSupport.optionalValue(flag: "--session-name", in: arguments)
        let routingEnabled = arguments.contains("--routing")
        let debugRouting = arguments.contains("--debug-routing")
        let routingModeValue = CommandSupport.optionalValue(flag: "--routing-mode", in: arguments)
        let routerModel = CommandSupport.optionalValue(flag: "--router", in: arguments)
        let codingModel = CommandSupport.optionalValue(flag: "--coding-model", in: arguments)
        let fallbackModel = CommandSupport.optionalValue(flag: "--fallback-model", in: arguments)
        let maxTokens = Int(CommandSupport.optionalValue(flag: "--max-tokens", in: arguments) ?? "") ?? GenerationConfig().maxTokens
        let temperature = Double(CommandSupport.optionalValue(flag: "--temperature", in: arguments) ?? "") ?? GenerationConfig().temperature
        let topP = try optionalDouble(flag: "--top-p", in: arguments)
        let topK = try optionalInt(flag: "--top-k", in: arguments)
        let minP = try optionalDouble(flag: "--min-p", in: arguments)
        let repetitionPenalty = try optionalDouble(flag: "--repetition-penalty", in: arguments)
        let seed = try optionalUInt64(flag: "--seed", in: arguments)
        let enableThinking = arguments.contains("--enable-thinking") ? true : nil
        let thinkingBudget = try optionalInt(flag: "--thinking-budget", in: arguments)
        let thinkingStartToken = CommandSupport.optionalValue(flag: "--thinking-start-token", in: arguments)
        let thinkingEndToken = CommandSupport.optionalValue(flag: "--thinking-end-token", in: arguments)
        let kvBits = try optionalDouble(flag: "--kv-bits", in: arguments)
        let kvQuantScheme = CommandSupport.optionalValue(flag: "--kv-quant-scheme", in: arguments)
        let kvGroupSize = try optionalInt(flag: "--kv-group-size", in: arguments)
        let quantizedKVStart = try optionalInt(flag: "--quantized-kv-start", in: arguments)

        let cacheArtifactID: UUID?
        if let artifactValue {
            guard let parsed = UUID(uuidString: artifactValue) else {
                throw StoreError.invalidManifest("Invalid artifact UUID: \(artifactValue)")
            }
            cacheArtifactID = parsed
        } else {
            cacheArtifactID = nil
        }

        let cacheMode: CacheMode?
        if let cacheModeValue {
            guard let parsed = CacheMode(rawValue: cacheModeValue.lowercased()) else {
                throw StoreError.invalidManifest("Invalid cache mode: \(cacheModeValue)")
            }
            cacheMode = parsed
        } else {
            cacheMode = nil
        }

        let intent: SessionIntent?
        if let intentValue {
            guard let parsed = SessionIntent(rawValue: intentValue.lowercased()) else {
                throw StoreError.invalidManifest("Invalid session intent: \(intentValue)")
            }
            intent = parsed
        } else {
            intent = nil
        }

        var messages: [ExternalInferenceMessage] = []
        if let systemPrompt, systemPrompt.isEmpty == false {
            messages.append(ExternalInferenceMessage(role: .system, text: systemPrompt))
        }
        messages.append(ExternalInferenceMessage(role: .user, text: message))

        let routing = try resolveRoutingConfiguration(
            enabled: routingEnabled || routingModeValue != nil || routerModel != nil || codingModel != nil || fallbackModel != nil || debugRouting,
            modeValue: routingModeValue,
            routerModel: routerModel,
            mainModel: model,
            codingModel: codingModel,
            fallbackModel: fallbackModel
        )

        return ExternalInferenceRequest(
            model: model,
            cacheArtifactID: cacheArtifactID,
            sessionName: sessionName,
            cacheMode: cacheMode,
            intent: intent,
            messages: messages,
            generation: GenerationConfig(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP,
                topK: topK,
                minP: minP,
                repetitionPenalty: repetitionPenalty,
                seed: seed,
                enableThinking: enableThinking,
                thinkingBudget: thinkingBudget,
                thinkingStartToken: thinkingStartToken,
                thinkingEndToken: thinkingEndToken,
                kvBits: kvBits,
                kvQuantScheme: kvQuantScheme,
                kvGroupSize: kvGroupSize,
                quantizedKVStart: quantizedKVStart
            ),
            routing: routing
        )
    }

    private static func optionalDouble(flag: String, in arguments: [String]) throws -> Double? {
        guard let value = CommandSupport.optionalValue(flag: flag, in: arguments) else { return nil }
        guard let parsed = Double(value) else {
            throw StoreError.invalidManifest("Invalid \(flag) value: \(value)")
        }
        return parsed
    }

    private static func optionalInt(flag: String, in arguments: [String]) throws -> Int? {
        guard let value = CommandSupport.optionalValue(flag: flag, in: arguments) else { return nil }
        guard let parsed = Int(value) else {
            throw StoreError.invalidManifest("Invalid \(flag) value: \(value)")
        }
        return parsed
    }

    private static func optionalUInt64(flag: String, in arguments: [String]) throws -> UInt64? {
        guard let value = CommandSupport.optionalValue(flag: flag, in: arguments) else { return nil }
        guard let parsed = UInt64(value) else {
            throw StoreError.invalidManifest("Invalid \(flag) value: \(value)")
        }
        return parsed
    }

    private static func resolveRoutingConfiguration(
        enabled: Bool,
        modeValue: String?,
        routerModel: String?,
        mainModel: String?,
        codingModel: String?,
        fallbackModel: String?
    ) throws -> RoutingConfiguration? {
        guard enabled else { return nil }
        var config = (try? RoutingConfigurationStore().load()) ?? RoutingConfiguration()
        config.enabled = true
        if config.mode == .disabled {
            config.mode = .sequential
        }
        if let modeValue {
            guard let mode = RoutingMode(rawValue: modeValue.lowercased()) else {
                throw StoreError.invalidManifest("Invalid routing mode: \(modeValue)")
            }
            config.mode = mode
            config.enabled = mode != .disabled
        }
        config.routerModel = routerModel ?? config.routerModel
        config.mainModel = mainModel ?? config.mainModel
        config.codingModel = codingModel ?? config.codingModel
        config.fallbackModel = fallbackModel ?? config.fallbackModel
        return config
    }

    private static func readInput(path: String) throws -> Data {
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.isEmpty == false else {
                throw StoreError.invalidManifest("Expected JSON infer request on stdin.")
            }
            return data
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func printRoutingDebug(_ routing: RoutingTrace) {
        let lines = [
            "Router model: \(routing.routerModel ?? "-")",
            "Router decision: \(routing.decision?.action.rawValue ?? "-")",
            "Target role: \(routing.decision?.targetModelRole.rawValue ?? "-")",
            "Confidence: \(routing.decision.map { String($0.confidence) } ?? "-")",
            "Routing latency: \(routing.routingLatencyMilliseconds.map { "\($0)ms" } ?? "-")",
            "Selected model: \(routing.selectedModel ?? "-")",
            "Fallback: \(routing.fallbackReason ?? "-")"
        ]
        let output = lines.joined(separator: "\n") + "\n"
        if let data = output.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
