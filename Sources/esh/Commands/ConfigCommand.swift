import Foundation
import EshCore

enum ConfigCommand {
    static func run(arguments: [String], root: PersistenceRoot) throws {
        for line in try outputLines(arguments: arguments, root: root) {
            print(line)
        }
    }

    static func outputLines(arguments: [String], root: PersistenceRoot) throws -> [String] {
        let store = EshConfigStore(root: root)
        let subcommand = arguments.first ?? "show"
        switch subcommand {
        case "init":
            let force = arguments.contains("--force")
            let created = try store.initializeIfNeeded(force: force)
            return [
                "\(created ? "created" : "exists"): \(store.configURL.path)"
            ]
        case "show":
            return try store.displayText().trimmingCharacters(in: .newlines).components(separatedBy: .newlines)
        case "path":
            return [store.configURL.path]
        case "set-speech":
            var config = try store.load()
            if let tts = CommandSupport.optionalValue(flag: "--tts", in: arguments) {
                config.defaults.ttsModel = tts.isEmpty ? nil : tts
            }
            if let stt = CommandSupport.optionalValue(flag: "--stt", in: arguments) {
                config.defaults.sttModel = stt.isEmpty ? nil : stt
            }
            try store.save(config)
            return [
                "tts_model: \(config.defaults.ttsModel ?? "(built-in default)")",
                "stt_model: \(config.defaults.sttModel ?? "(built-in default: parakeet)")"
            ]
        default:
            throw StoreError.invalidManifest("Usage: esh config init [--force] | esh config show | esh config path | esh config set-speech [--tts <id>] [--stt <id>]")
        }
    }
}
