import Foundation
import Darwin
import EshCore

enum IntegrationsCommand {
    private static let defaultOpenAIPort: UInt16 = 11435
    private static let defaultAnthropicPort: UInt16 = 11436
    private static let defaultAPIKey = "esh-local"

    static func run(arguments: [String], root: PersistenceRoot, toolVersion: String?) async throws {
        let service = ExternalIntegrationService()
        guard let subcommand = arguments.first else {
            throw StoreError.invalidManifest(usage)
        }

        switch subcommand {
        case "list":
            try list(service: service)
        case "show":
            guard let identifier = arguments.dropFirst().first else {
                throw StoreError.invalidManifest(usage)
            }
            try show(identifier: identifier, service: service)
        case "configure":
            try configure(arguments: Array(arguments.dropFirst()), root: root, service: service)
        case "launch":
            try await launch(arguments: Array(arguments.dropFirst()), root: root, toolVersion: toolVersion, service: service)
        default:
            throw StoreError.invalidManifest(usage)
        }
    }

    static func launchShortcut(arguments: [String], root: PersistenceRoot, toolVersion: String?) async throws {
        try await launch(arguments: arguments, root: root, toolVersion: toolVersion, service: ExternalIntegrationService())
    }

    private static var usage: String {
        """
        Usage:
          esh integrations list
          esh integrations show <claude|codex>
          esh integrations configure <claude|codex> [--model <id-or-repo>] [--host <host>] [--port <port>] [--api-key <token>]
          esh integrations launch <claude|codex> [--model <id-or-repo>] [--host <host>] [--port <port>] [--api-key <token>] [-- <tool-args...>]
          esh launch <claude|codex> [--model <id-or-repo>] [--host <host>] [--port <port>] [--api-key <token>] [-- <tool-args...>]
        """
    }

    private static func list(service: ExternalIntegrationService) throws {
        for descriptor in service.list() {
            let installed = commandExists(named: descriptor.executableName) ? "installed" : "missing"
            print("\(descriptor.id.rawValue): \(descriptor.displayName)")
            print("  executable: \(descriptor.executableName) (\(installed))")
            print("  protocol: \(descriptor.serverProtocol.rawValue)")
            print("  install: \(descriptor.installCommand)")
            print("  docs: \(descriptor.docsURL)")
        }
    }

    private static func show(identifier: String, service: ExternalIntegrationService) throws {
        let descriptor = try service.descriptor(named: identifier)
        print("id: \(descriptor.id.rawValue)")
        print("name: \(descriptor.displayName)")
        print("executable: \(descriptor.executableName)")
        print("installed: \(commandExists(named: descriptor.executableName) ? "yes" : "no")")
        print("protocol: \(descriptor.serverProtocol.rawValue)")
        print("install: \(descriptor.installCommand)")
        print("docs: \(descriptor.docsURL)")
    }

    private static func launch(
        arguments: [String],
        root: PersistenceRoot,
        toolVersion: String?,
        service: ExternalIntegrationService
    ) async throws {
        guard let identifier = arguments.first else {
            throw StoreError.invalidManifest(usage)
        }
        let descriptor = try service.descriptor(named: identifier)
        guard commandExists(named: descriptor.executableName) else {
            throw StoreError.notFound("`\(descriptor.executableName)` is not installed. Run `\(descriptor.installCommand)` first.")
        }

        let (launchArguments, passthroughArguments) = splitPassthrough(Array(arguments.dropFirst()))
        let modelStore = FileModelStore(root: root)
        let install = try CommandSupport.resolveInstall(
            identifier: CommandSupport.optionalValue(flag: "--model", in: launchArguments),
            modelStore: modelStore
        )
        let apiKey = resolveAPIKey(
            arguments: launchArguments,
            defaultValue: descriptor.id == .claude ? defaultAPIKey : nil
        )
        let host = CommandSupport.optionalValue(flag: "--host", in: launchArguments) ?? "127.0.0.1"
        let workspaceRootURL = WorkspaceContextLocator(root: root).workspaceRootURL(
            from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        )

        let baseURL: String
        let port: UInt16
        switch descriptor.serverProtocol {
        case .openAICompatible:
            port = try resolvePort(arguments: launchArguments, defaultPort: defaultOpenAIPort)
            baseURL = "http://\(host):\(port)/v1"
        case .anthropicCompatible:
            port = try resolvePort(arguments: launchArguments, defaultPort: defaultAnthropicPort)
            baseURL = "http://\(host):\(port)"
        }

        let plan = try service.launchPlan(
            integrationID: descriptor.id.rawValue,
            modelID: install.id,
            baseURL: baseURL,
            apiKey: apiKey,
            workspaceRootURL: workspaceRootURL,
            passthroughArguments: passthroughArguments
        )

        let server = try makeServer(
            descriptor: descriptor,
            root: root,
            toolVersion: toolVersion,
            host: host,
            port: port,
            apiKey: apiKey
        )
        server.start()
        defer { server.stop() }

        let tempRoot = try temporaryLaunchRoot(for: descriptor.id)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var environment = plan.environment
        if let config = plan.configurationFileContents {
            let codexHome = tempRoot.appendingPathComponent("codex-home", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try config.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            environment["CODEX_HOME"] = codexHome.path
        }

        let executableURL = try resolveExecutable(named: plan.executableName)
        print("Launching \(descriptor.displayName) with model \(install.id) via \(baseURL)")
        let exitCode = try runInteractiveProcess(
            executableURL: executableURL,
            arguments: plan.arguments,
            environment: environment,
            currentDirectoryURL: workspaceRootURL
        )
        guard exitCode == 0 else {
            throw StoreError.invalidManifest("\(descriptor.displayName) exited with status \(exitCode).")
        }
    }

    private static func configure(
        arguments: [String],
        root: PersistenceRoot,
        service: ExternalIntegrationService
    ) throws {
        guard let identifier = arguments.first else {
            throw StoreError.invalidManifest(usage)
        }
        let descriptor = try service.descriptor(named: identifier)

        let configureArguments = Array(arguments.dropFirst())
        let modelStore = FileModelStore(root: root)
        let install = try CommandSupport.resolveInstall(
            identifier: CommandSupport.optionalValue(flag: "--model", in: configureArguments),
            modelStore: modelStore
        )
        let host = CommandSupport.optionalValue(flag: "--host", in: configureArguments) ?? "127.0.0.1"
        let apiKey = resolveAPIKey(
            arguments: configureArguments,
            defaultValue: descriptor.id == .claude ? defaultAPIKey : nil
        )

        switch descriptor.id {
        case .codex:
            let port = try resolvePort(arguments: configureArguments, defaultPort: defaultOpenAIPort)
            let baseURL = "http://\(host):\(port)/v1"
            let workspaceRootURL = WorkspaceContextLocator(root: root).workspaceRootURL(
                from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            )

            let codexHome = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            let configURL = codexHome.appendingPathComponent("config.toml")
            let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            let merged = service.mergedCodexConfiguration(
                existingConfiguration: existing,
                modelID: install.id,
                baseURL: baseURL,
                requiresAPIKey: apiKey != nil,
                workspaceRootURL: workspaceRootURL
            )
            try merged.write(to: configURL, atomically: true, encoding: .utf8)

            print("Configured Codex profile `\(ExternalIntegrationService.codexProfileName)` at \(configURL.path)")
            print("Start Esh with: esh serve --host \(host) --port \(port)")
            if apiKey == nil {
                print("Run Codex with: codex --profile \(ExternalIntegrationService.codexProfileName)")
            } else {
                print("Run Codex with: OPENAI_API_KEY=<your-api-key> codex --profile \(ExternalIntegrationService.codexProfileName)")
            }
        case .claude:
            let port = try resolvePort(arguments: configureArguments, defaultPort: defaultAnthropicPort)
            let baseURL = "http://\(host):\(port)"
            let claudeHome = URL(fileURLWithPath: "\(NSHomeDirectory())/.claude", isDirectory: true)
            try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
            let settingsURL = claudeHome.appendingPathComponent("settings.json")
            let existing = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? ""
            let merged = try service.mergedClaudeSettings(
                existingSettings: existing,
                modelID: install.id,
                baseURL: baseURL,
                apiKey: apiKey ?? defaultAPIKey
            )
            try merged.write(to: settingsURL, atomically: true, encoding: .utf8)

            print("Configured Claude Code environment at \(settingsURL.path)")
            print("Run Claude Code with: claude --model \(install.id)")
        }
    }

    private static func splitPassthrough(_ arguments: [String]) -> ([String], [String]) {
        guard let separatorIndex = arguments.firstIndex(of: "--") else {
            return (arguments, [])
        }
        return (
            Array(arguments[..<separatorIndex]),
            Array(arguments[arguments.index(after: separatorIndex)...])
        )
    }

    private static func resolvePort(arguments: [String], defaultPort: UInt16) throws -> UInt16 {
        guard let rawPort = CommandSupport.optionalValue(flag: "--port", in: arguments) else {
            return defaultPort
        }
        guard let port = UInt16(rawPort), port > 0 else {
            throw StoreError.invalidManifest("Invalid port `\(rawPort)`.")
        }
        return port
    }

    private static func resolveAPIKey(arguments: [String], defaultValue: String?) -> String? {
        if let apiKey = CommandSupport.optionalValue(flag: "--api-key", in: arguments), apiKey.isEmpty == false {
            return apiKey
        }
        if let apiKey = ProcessInfo.processInfo.environment["ESH_API_KEY"], apiKey.isEmpty == false {
            return apiKey
        }
        return defaultValue
    }

    private static func makeServer(
        descriptor: ExternalIntegrationDescriptor,
        root: PersistenceRoot,
        toolVersion: String?,
        host: String,
        port: UInt16,
        apiKey: String?
    ) throws -> OpenAICompatibleLocalServer {
        switch descriptor.serverProtocol {
        case .openAICompatible:
            let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let service = OpenAICompatibleService(
                modelStore: FileModelStore(root: root),
                sessionStore: FileSessionStore(root: root),
                cacheStore: FileCacheStore(root: root),
                toolVersion: toolVersion,
                audioModels: OpenAICompatibleAudioCatalog.ttsModels,
                speech: { request in
                    try await AudioSpeechGenerator.generateResponse(request, currentDirectoryURL: currentDirectoryURL)
                }
            )
            let handler = OpenAICompatibleHTTPHandler(service: service, bearerToken: apiKey)
            return try OpenAICompatibleLocalServer(host: host, port: port, handler: handler)
        case .anthropicCompatible:
            let service = AnthropicCompatibleService(
                modelStore: FileModelStore(root: root),
                sessionStore: FileSessionStore(root: root),
                cacheStore: FileCacheStore(root: root),
                toolVersion: toolVersion
            )
            let handler = AnthropicCompatibleHTTPHandler(service: service, apiKey: apiKey)
            return try OpenAICompatibleLocalServer(host: host, port: port, handler: handler.handle)
        }
    }

    private static func resolveExecutable(named name: String) throws -> URL {
        let output = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", name]
        )
        guard output.exitCode == 0,
              let path = String(data: output.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false else {
            throw StoreError.notFound("Could not resolve executable `\(name)`.")
        }
        return URL(fileURLWithPath: path)
    }

    private static func commandExists(named name: String) -> Bool {
        let output = try? ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", name]
        )
        return output?.exitCode == 0
    }

    private static func temporaryLaunchRoot(for integrationID: ExternalIntegrationID) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("esh-\(integrationID.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func runInteractiveProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
