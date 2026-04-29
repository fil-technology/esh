import Foundation
import EshCore

enum ConfigCommand {
    static func run(arguments: [String], root: PersistenceRoot) throws {
        let store = OrchestratorConfigurationStore(root: root)
        let subcommand = arguments.first ?? "show"

        switch subcommand {
        case "path":
            print(store.configURL.path)
        case "show":
            print(showText(configuration: try store.load(), configURL: store.configURL))
        case "init":
            let force = arguments.contains("--force")
            if FileManager.default.fileExists(atPath: store.configURL.path), !force {
                throw StoreError.invalidManifest("Config already exists at \(store.configURL.path). Use `esh config init --force` to overwrite it.")
            }
            try store.save(.default)
            print("wrote: \(store.configURL.path)")
        default:
            throw StoreError.invalidManifest("Usage: esh config [show|path|init] [--force]")
        }
    }

    static func showText(configuration: OrchestratorConfiguration, configURL: URL) -> String {
        """
        path: \(configURL.path)

        \(configuration.tomlString())
        """
    }
}
