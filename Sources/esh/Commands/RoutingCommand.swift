import Foundation
import EshCore

enum RoutingCommand {
    static func run(arguments: [String], root: PersistenceRoot, currentDirectoryURL: URL) async throws {
        let store = RoutingConfigurationStore(root: root)
        let subcommand = arguments.first ?? "status"

        switch subcommand {
        case "status":
            printStatus(try store.load())
        case "enable":
            var config = try store.load()
            config.enabled = true
            if config.mode == .disabled {
                config.mode = .sequential
            }
            try store.save(config)
            printStatus(config)
        case "disable":
            var config = try store.load()
            config.enabled = false
            config.mode = .disabled
            try store.save(config)
            printStatus(config)
        case "set-router":
            try setRole(.router, arguments: arguments, store: store)
        case "set-main":
            try setRole(.main, arguments: arguments, store: store)
        case "set-coding":
            try setRole(.coding, arguments: arguments, store: store)
        case "set-fallback":
            try setRole(.fallback, arguments: arguments, store: store)
        case "set-mode":
            guard let value = arguments.dropFirst().first,
                  let mode = RoutingMode(rawValue: value.lowercased()) else {
                throw StoreError.invalidManifest("Usage: esh routing set-mode disabled|single|sequential|parallel")
            }
            var config = try store.load()
            config.mode = mode
            config.enabled = mode != .disabled
            try store.save(config)
            printStatus(config)
        case "test":
            let positional = CommandSupport.positionalArguments(in: Array(arguments.dropFirst()), knownFlags: [])
            guard positional.isEmpty == false else {
                throw StoreError.invalidManifest("Usage: esh routing test <prompt>")
            }
            let prompt = positional.joined(separator: " ")
            let config = try store.load()
            let service = ExternalInferenceService(
                modelStore: FileModelStore(root: root),
                sessionStore: FileSessionStore(root: root),
                cacheStore: FileCacheStore(root: root),
                workspaceRootURL: WorkspaceContextLocator().workspaceRootURL(from: currentDirectoryURL)
            )
            let request = ExternalInferenceRequest(
                model: config.mainModel,
                messages: [ExternalInferenceMessage(role: .user, text: prompt)],
                generation: GenerationConfig(maxTokens: 256, temperature: config.mainTemperature),
                routing: config.enabled ? config : enabledCopy(config)
            )
            let response = try await service.infer(request: request)
            let data = try JSONCoding.encoder.encode(response.routing)
            print(String(decoding: data, as: UTF8.self))
            if response.outputText.isEmpty == false {
                print("output_preview: \(String(response.outputText.prefix(240)))")
            }
        default:
            throw StoreError.invalidManifest("Usage: esh routing status|enable|disable|set-mode|set-router|set-main|set-coding|set-fallback|test")
        }
    }

    private static func setRole(
        _ role: ModelRole,
        arguments: [String],
        store: RoutingConfigurationStore
    ) throws {
        guard let modelID = arguments.dropFirst().first else {
            throw StoreError.invalidManifest("Usage: esh routing set-\(role.rawValue) <model-id>")
        }
        var config = try store.load()
        switch role {
        case .router:
            config.routerModel = modelID
        case .main:
            config.mainModel = modelID
        case .coding:
            config.codingModel = modelID
        case .fallback:
            config.fallbackModel = modelID
        case .embedding:
            config.embeddingModel = modelID
        }
        try store.save(config)
        printStatus(config)
    }

    private static func enabledCopy(_ config: RoutingConfiguration) -> RoutingConfiguration {
        var copy = config
        copy.enabled = true
        if copy.mode == .disabled {
            copy.mode = .sequential
        }
        return copy
    }

    private static func printStatus(_ config: RoutingConfiguration) {
        print("enabled: \(config.enabled)")
        print("mode: \(config.mode.rawValue)")
        print("router_model: \(config.routerModel ?? "-")")
        print("main_model: \(config.mainModel ?? "-")")
        print("coding_model: \(config.codingModel ?? "-")")
        print("fallback_model: \(config.fallbackModel ?? "-")")
        print("max_router_tokens: \(config.maxRouterTokens)")
        print("router_temperature: \(config.routerTemperature)")
        print("main_temperature: \(config.mainTemperature)")
        print("minimum_confidence: \(config.minimumConfidence)")
    }
}
