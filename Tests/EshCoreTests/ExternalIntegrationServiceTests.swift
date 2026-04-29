import Foundation
import Testing
@testable import EshCore

@Suite
struct ExternalIntegrationServiceTests {
    @Test
    func listIncludesCodexAndClaudeWithExpectedProtocols() throws {
        let service = ExternalIntegrationService()

        let descriptors = service.list()

        #expect(descriptors.map(\.id) == [.claude, .codex])
        #expect(descriptors.first(where: { $0.id == .codex })?.serverProtocol == .openAICompatible)
        #expect(descriptors.first(where: { $0.id == .claude })?.serverProtocol == .anthropicCompatible)
    }

    @Test
    func codexLaunchPlanUsesResponsesProviderConfig() throws {
        let service = ExternalIntegrationService()

        let plan = try service.launchPlan(
            integrationID: "codex",
            modelID: "mlx-demo",
            baseURL: "http://127.0.0.1:11435/v1",
            apiKey: "esh-demo-key",
            workspaceRootURL: URL(fileURLWithPath: "/tmp/worktree", isDirectory: true),
            passthroughArguments: ["exec", "Say hello"]
        )

        #expect(plan.integrationID == .codex)
        #expect(plan.executableName == "codex")
        #expect(plan.serverProtocol == .openAICompatible)
        #expect(plan.arguments == [
            "-c", "model_providers.esh={name=\"Esh\",base_url=\"http://127.0.0.1:11435/v1\",env_key=\"OPENAI_API_KEY\",wire_api=\"responses\"}",
            "-c", "model_provider=\"esh\"",
            "-c", "model=\"mlx-demo\"",
            "exec",
            "Say hello"
        ])
        #expect(plan.environment["OPENAI_API_KEY"] == "esh-demo-key")
        let config = try #require(plan.configurationFileContents)
        #expect(config.contains("[profiles.esh-launch]"))
        #expect(config.contains("[model_providers.esh-launch]"))
        #expect(config.contains("base_url = \"http://127.0.0.1:11435/v1\""))
        #expect(config.contains("env_key = \"OPENAI_API_KEY\""))
        #expect(config.contains("wire_api = \"responses\""))
        #expect(config.contains("model_provider = \"esh-launch\""))
        #expect(config.contains("model = \"mlx-demo\""))
        #expect(config.contains("projects.\"/tmp/worktree\""))
    }

    @Test
    func codexLaunchPlanDoesNotRequireAPIKeyByDefault() throws {
        let service = ExternalIntegrationService()

        let plan = try service.launchPlan(
            integrationID: "codex",
            modelID: "mlx-demo",
            baseURL: "http://127.0.0.1:11435/v1",
            apiKey: nil,
            workspaceRootURL: nil,
            passthroughArguments: []
        )

        #expect(plan.environment["OPENAI_API_KEY"] == nil)
        #expect(plan.arguments.first(where: { $0.contains("model_providers.esh") })?.contains("env_key") == false)
        #expect(plan.arguments.contains("model=\"mlx-demo\""))
        let config = try #require(plan.configurationFileContents)
        #expect(config.contains("env_key") == false)
    }

    @Test
    func mergedCodexConfigurationReplacesExistingEshLaunchSections() {
        let service = ExternalIntegrationService()
        let existing = """
        model = "gpt-5"

        [profiles.esh-launch]
        model = "old"
        model_provider = "esh-launch"

        [model_providers.esh-launch]
        name = "Old Esh"
        base_url = "http://127.0.0.1:9999/v1/"

        [profiles.other]
        model = "keep-me"
        """

        let merged = service.mergedCodexConfiguration(
            existingConfiguration: existing,
            modelID: "mlx-demo",
            baseURL: "http://127.0.0.1:11435/v1",
            workspaceRootURL: nil
        )

        #expect(merged.contains("model = \"gpt-5\""))
        #expect(merged.contains("[profiles.other]"))
        #expect(merged.contains("model = \"keep-me\""))
        #expect(merged.contains("[profiles.esh-launch]"))
        #expect(merged.contains("model = \"mlx-demo\""))
        #expect(merged.contains("[model_providers.esh-launch]"))
        #expect(merged.contains("base_url = \"http://127.0.0.1:11435/v1\""))
        #expect(merged.contains("env_key = \"OPENAI_API_KEY\"") == false)
        #expect(merged.contains("wire_api = \"responses\""))
        #expect(merged.contains("old") == false)
        #expect(merged.contains("9999") == false)
    }

    @Test
    func mergedCodexConfigurationReplacesExistingWorkspaceTrustSection() {
        let service = ExternalIntegrationService()
        let workspaceURL = URL(fileURLWithPath: "/tmp/worktree", isDirectory: true)
        let existing = """
        model = "gpt-5"

        [projects."/tmp/worktree"]
        trust_level = "trusted"

        [profiles.other]
        model = "keep-me"
        """

        let merged = service.mergedCodexConfiguration(
            existingConfiguration: existing,
            modelID: "mlx-demo",
            baseURL: "http://127.0.0.1:11435/v1",
            workspaceRootURL: workspaceURL
        )

        #expect(merged.components(separatedBy: "[projects.\"/tmp/worktree\"]").count == 2)
        #expect(merged.contains("[profiles.other]"))
        #expect(merged.contains("[profiles.esh-launch]"))
        #expect(merged.contains("[model_providers.esh-launch]"))
    }

    @Test
    func claudeLaunchPlanUsesAnthropicEnvironmentVariables() throws {
        let service = ExternalIntegrationService()

        let plan = try service.launchPlan(
            integrationID: "claude",
            modelID: "mlx-demo",
            baseURL: "http://127.0.0.1:11436",
            apiKey: "esh-demo-key",
            workspaceRootURL: nil,
            passthroughArguments: ["-p", "Say hello"]
        )

        #expect(plan.integrationID == .claude)
        #expect(plan.executableName == "claude")
        #expect(plan.serverProtocol == .anthropicCompatible)
        #expect(plan.arguments == ["--model", "mlx-demo", "-p", "Say hello"])
        #expect(plan.environment["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:11436")
        #expect(plan.environment["ANTHROPIC_AUTH_TOKEN"] == "esh-demo-key")
        #expect(plan.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(plan.environment["ANTHROPIC_CUSTOM_MODEL_OPTION"] == "mlx-demo")
        #expect(plan.environment["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"] == "Esh local model")
        #expect(plan.configurationFileContents == nil)
    }

    @Test
    func mergedClaudeSettingsPreservesExistingSettingsAndAddsLocalEnvironment() throws {
        let service = ExternalIntegrationService()
        let existing = """
        {
          "permissions": {
            "allow": ["Bash(swift test)"]
          },
          "env": {
            "KEEP_ME": "yes",
            "ANTHROPIC_BASE_URL": "https://api.anthropic.com"
          }
        }
        """

        let merged = try service.mergedClaudeSettings(
            existingSettings: existing,
            modelID: "mlx-demo",
            baseURL: "http://127.0.0.1:11436",
            apiKey: "esh-demo-key"
        )
        let decoded = try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
        let env = try #require(decoded?["env"] as? [String: String])
        let permissions = try #require(decoded?["permissions"] as? [String: Any])

        #expect(env["KEEP_ME"] == "yes")
        #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:11436")
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == "esh-demo-key")
        #expect(env["ANTHROPIC_CUSTOM_MODEL_OPTION"] == "mlx-demo")
        #expect(env["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"] == "Esh local model")
        #expect(permissions["allow"] != nil)
    }
}
