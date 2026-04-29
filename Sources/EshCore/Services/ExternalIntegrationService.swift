import Foundation

public struct ExternalIntegrationService: Sendable {
    public static let codexProfileName = "esh-launch"
    public static let codexProviderName = "esh-launch"

    public init() {}

    public func list() -> [ExternalIntegrationDescriptor] {
        [
            ExternalIntegrationDescriptor(
                id: .claude,
                displayName: "Claude Code",
                executableName: "claude",
                installCommand: "npm install -g @anthropic-ai/claude-code",
                docsURL: "https://docs.anthropic.com/en/docs/claude-code/getting-started",
                serverProtocol: .anthropicCompatible
            ),
            ExternalIntegrationDescriptor(
                id: .codex,
                displayName: "Codex CLI",
                executableName: "codex",
                installCommand: "npm install -g @openai/codex",
                docsURL: "https://developers.openai.com/codex/quickstart",
                serverProtocol: .openAICompatible
            )
        ]
    }

    public func descriptor(named name: String) throws -> ExternalIntegrationDescriptor {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let descriptor = list().first(where: {
            $0.id.rawValue == normalized || $0.executableName == normalized
        }) else {
            throw StoreError.notFound("Unknown integration `\(name)`. Use `esh integrations list`.")
        }
        return descriptor
    }

    public func launchPlan(
        integrationID: String,
        modelID: String,
        baseURL: String,
        apiKey: String?,
        workspaceRootURL: URL?,
        passthroughArguments: [String]
    ) throws -> ExternalIntegrationLaunchPlan {
        let descriptor = try descriptor(named: integrationID)

        switch descriptor.id {
        case .claude:
            return ExternalIntegrationLaunchPlan(
                integrationID: descriptor.id,
                executableName: descriptor.executableName,
                serverProtocol: descriptor.serverProtocol,
                arguments: ["--model", modelID] + passthroughArguments,
                environment: [
                    "ANTHROPIC_BASE_URL": baseURL,
                    "ANTHROPIC_AUTH_TOKEN": apiKey ?? "esh-local",
                    "ANTHROPIC_CUSTOM_MODEL_OPTION": modelID,
                    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Esh local model"
                ]
            )
        case .codex:
            var environment: [String: String] = [:]
            if let apiKey {
                environment["OPENAI_API_KEY"] = apiKey
            }
            return ExternalIntegrationLaunchPlan(
                integrationID: descriptor.id,
                executableName: descriptor.executableName,
                serverProtocol: descriptor.serverProtocol,
                arguments: codexArguments(
                    modelID: modelID,
                    baseURL: baseURL,
                    requiresAPIKey: apiKey != nil,
                    passthroughArguments: passthroughArguments
                ),
                environment: environment,
                configurationFileContents: codexConfiguration(
                    modelID: modelID,
                    baseURL: baseURL,
                    requiresAPIKey: apiKey != nil,
                    workspaceRootURL: workspaceRootURL
                )
            )
        }
    }

    private func codexConfiguration(
        modelID: String,
        baseURL: String,
        requiresAPIKey: Bool,
        workspaceRootURL: URL?
    ) -> String {
        var lines: [String] = [
            "[profiles.\(Self.codexProfileName)]",
            "forced_login_method = \"api\"",
            "model = \"\(modelID)\"",
            "model_provider = \"\(Self.codexProviderName)\"",
            "model_reasoning_effort = \"medium\"",
            "",
            "[model_providers.\(Self.codexProviderName)]",
            "name = \"Esh\"",
            "base_url = \"\(baseURL)\"",
            "wire_api = \"responses\""
        ]
        if requiresAPIKey {
            lines.insert("env_key = \"OPENAI_API_KEY\"", at: lines.count - 1)
        }
        if let workspaceRootURL {
            lines.append("")
            lines.append("[projects.\"\(workspaceRootURL.path)\"]")
            lines.append("trust_level = \"trusted\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func mergedCodexConfiguration(
        existingConfiguration: String,
        modelID: String,
        baseURL: String,
        requiresAPIKey: Bool = false,
        workspaceRootURL: URL?
    ) -> String {
        let replacement = codexConfiguration(
            modelID: modelID,
            baseURL: baseURL,
            requiresAPIKey: requiresAPIKey,
            workspaceRootURL: workspaceRootURL
        )
        var sectionNames: Set<String> = [
            "profiles.\(Self.codexProfileName)",
            "model_providers.\(Self.codexProviderName)"
        ]
        if let workspaceRootURL {
            sectionNames.insert("projects.\"\(workspaceRootURL.path)\"")
        }
        let stripped = removeSections(named: sectionNames, from: existingConfiguration)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return replacement
        }
        return trimmed + "\n\n" + replacement
    }

    public func mergedClaudeSettings(
        existingSettings: String,
        modelID: String,
        baseURL: String,
        apiKey: String
    ) throws -> String {
        var settings = try decodeJSONObject(existingSettings)
        var environment = settings["env"] as? [String: Any] ?? [:]
        environment["ANTHROPIC_BASE_URL"] = baseURL
        environment["ANTHROPIC_AUTH_TOKEN"] = apiKey
        environment["ANTHROPIC_CUSTOM_MODEL_OPTION"] = modelID
        environment["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"] = "Esh local model"
        settings["env"] = environment

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidManifest("Could not encode Claude Code settings.")
        }
        return json + "\n"
    }

    private func removeSections(named sectionNames: Set<String>, from configuration: String) -> String {
        var output: [String] = []
        var shouldSkip = false
        for line in configuration.components(separatedBy: .newlines) {
            if let sectionName = tomlSectionName(from: line) {
                shouldSkip = sectionNames.contains(sectionName)
            }
            if shouldSkip == false {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    private func tomlSectionName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
    }

    private func decodeJSONObject(_ settings: String) throws -> [String: Any] {
        let trimmed = settings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw StoreError.invalidManifest("Claude Code settings were not valid UTF-8.")
        }
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let object = decoded as? [String: Any] else {
            throw StoreError.invalidManifest("Claude Code settings must be a JSON object.")
        }
        return object
    }

    private func codexArguments(
        modelID: String,
        baseURL: String,
        requiresAPIKey: Bool,
        passthroughArguments: [String]
    ) -> [String] {
        let providerConfig = requiresAPIKey
            ? #"model_providers.esh={name="Esh",base_url="\#(baseURL)",env_key="OPENAI_API_KEY",wire_api="responses"}"#
            : #"model_providers.esh={name="Esh",base_url="\#(baseURL)",wire_api="responses"}"#
        return [
            "-c", providerConfig,
            "-c", #"model_provider="esh""#,
            "-c", #"model="\#(modelID)""#
        ] + passthroughArguments
    }
}
