import Foundation
import Testing
@testable import EshCore

@Suite
struct ConfigMigrationTests {
    @Test
    func defaultConfigRoundTripsThroughTOML() throws {
        let original = EshConfig.default
        let parsed = try EshConfig(tomlText: original.tomlString)
        #expect(parsed == original)
        #expect(parsed.schemaVersion == EshConfig.currentSchemaVersion)
    }

    @Test
    func customValuesRoundTrip() throws {
        var config = EshConfig.default
        config.defaults.engine = "mlx"
        config.defaults.contextSize = 16384
        config.engines.llamaCpp.enabled = false
        config.experimental.transformers = true
        let parsed = try EshConfig(tomlText: config.tomlString)
        #expect(parsed == config)
    }

    @Test
    func capabilityModelPinsRoundTripThroughTOML() throws {
        var config = EshConfig.default
        config.defaults.capabilityModels["vector.generate"] = "mlx-community/some-chat-model"
        config.defaults.capabilityModels["image.understand"] = "mlx-community/nanollava"
        let parsed = try EshConfig(tomlText: config.tomlString)
        #expect(parsed == config)
        #expect(parsed.defaults.capabilityModels["vector.generate"] == "mlx-community/some-chat-model")
        #expect(parsed.defaults.capabilityModels["image.understand"] == "mlx-community/nanollava")
    }

    @Test
    func autoAndEmptyCapabilityPinsAreDropped() throws {
        var config = EshConfig.default
        config.defaults.capabilityModels["vector.generate"] = "auto"
        config.defaults.capabilityModels["language.generate"] = ""
        let parsed = try EshConfig(tomlText: config.tomlString)
        // "auto"/"" mean Auto — they are not persisted, so a clean config stays clean.
        #expect(parsed.defaults.capabilityModels.isEmpty)
    }

    @Test
    func legacyConfigWithoutSchemaVersionDefaultsToOne() throws {
        // A config file written by an older esh release (no [meta] section).
        let legacy = """
        [defaults]
        engine = "auto"
        model_dir = "~/.esh/models"
        context_size = 8192

        [engines.llama_cpp]
        enabled = true
        binary = "auto"
        metal = true

        [engines.mlx]
        enabled = true
        python = "auto"
        """
        let parsed = try EshConfig(tomlText: legacy)
        #expect(parsed.schemaVersion == 1)
        #expect(parsed.defaults.engine == "auto")
        #expect(parsed.defaults.contextSize == 8192)
    }

    @Test
    func deprecatedModelDirIsStillParsedButMarkedInOutput() throws {
        let legacy = """
        [defaults]
        model_dir = "/Volumes/AI/models"
        """
        let parsed = try EshConfig(tomlText: legacy)
        #expect(parsed.defaults.modelDir == "/Volumes/AI/models")
        // New output documents that model_dir is deprecated in favor of `esh storage`.
        #expect(EshConfig.default.tomlString.contains("model_dir is deprecated"))
        #expect(EshConfig.default.tomlString.contains("schema_version"))
    }

    @Test
    func jsonDecodeOfOldConfigWithoutSchemaVersionDefaults() throws {
        // Configs are TOML on disk, but EshConfig is also Codable; ensure old JSON without a
        // schemaVersion key still decodes.
        let json = Data(#"{"defaults":{"engine":"auto","modelDir":"~/.esh/models","contextSize":8192},"engines":{"llamaCpp":{"enabled":true,"binary":"auto","metal":true},"mlx":{"enabled":true,"python":"auto"}},"experimental":{"ollamaAdapter":false,"llamafile":false,"transformers":false,"llamaCppServer":false}}"#.utf8)
        let decoded = try JSONDecoder().decode(EshConfig.self, from: json)
        #expect(decoded.schemaVersion == 1)
    }

    @Test
    func legacyLLMCacheRootMigratesToEsh() throws {
        let home = temporaryDirectory()
        let legacy = home.appendingPathComponent(".llmcache", isDirectory: true)
        let esh = home.appendingPathComponent(".esh", isDirectory: true)
        let fm = FileManager.default
        // Seed a legacy models directory with a file.
        let legacyModel = legacy.appendingPathComponent("models/installs/demo", isDirectory: true)
        try fm.createDirectory(at: legacyModel, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: legacyModel.appendingPathComponent("model.safetensors"))

        PersistenceRoot.migrateLegacyRootIfNeeded(fileManager: fm, legacyRoot: legacy, eshRoot: esh)

        let migrated = esh.appendingPathComponent("models/installs/demo/model.safetensors")
        #expect(fm.fileExists(atPath: migrated.path))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
