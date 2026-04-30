import Foundation
import Testing
@testable import EshCore

@Suite
struct OrchestratorConfigTests {
    @Test
    func defaultConfigMatchesRoadmapToml() throws {
        let text = EshConfig.default.tomlString

        #expect(text.contains(#"engine = "auto""#))
        #expect(text.contains(#"model_dir = "~/.esh/models""#))
        #expect(text.contains("context_size = 8192"))
        #expect(text.contains("[engines.llama_cpp]"))
        #expect(text.contains(#"binary = "auto""#))
        #expect(text.contains("[engines.mlx]"))
        #expect(text.contains(#"python = "auto""#))
        #expect(text.contains("[experimental]"))
        #expect(text.contains("ollama_adapter = false"))

        let parsed = try EshConfig(tomlText: text)
        #expect(parsed.defaults.engine == "auto")
        #expect(parsed.defaults.modelDir == "~/.esh/models")
        #expect(parsed.defaults.contextSize == 8192)
        #expect(parsed.engines.llamaCpp.enabled)
        #expect(parsed.engines.llamaCpp.binary == "auto")
        #expect(parsed.engines.llamaCpp.metal)
        #expect(parsed.engines.mlx.enabled)
        #expect(parsed.engines.mlx.python == "auto")
        #expect(parsed.experimental.ollamaAdapter == false)
        #expect(parsed.experimental.llamafile == false)
        #expect(parsed.experimental.transformers == false)
        #expect(parsed.experimental.llamaCppServer == false)
    }

    @Test
    func configStoreInitializesAndLoadsDefaultFile() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let store = EshConfigStore(root: root)

        let created = try store.initializeIfNeeded()

        #expect(created)
        #expect(store.configURL.path.hasSuffix(".esh/config.toml") == false)
        #expect(FileManager.default.fileExists(atPath: store.configURL.path))
        #expect(try store.load().defaults.engine == "auto")
        #expect(try String(contentsOf: store.configURL).contains("[engines.llama_cpp]"))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
