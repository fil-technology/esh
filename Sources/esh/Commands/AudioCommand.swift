import Foundation
import EshCore
import TTSMLX

enum AudioCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) async throws {
        guard let subcommand = arguments.first else {
            throw StoreError.invalidManifest("Usage: esh audio speak <text> [--model <id>] [--voice <id>] [--language <name>] [--out <path>] [--play] [--force]")
        }

        switch subcommand {
        case "models":
            listTTSModels()
        case "speak":
            try await speak(arguments: Array(arguments.dropFirst()), currentDirectoryURL: currentDirectoryURL)
        case "transcribe":
            throw StoreError.invalidManifest("Audio transcription is not wired yet. TTSMLX currently exposes MLX TTS only; STT remains a later backend slice.")
        default:
            throw StoreError.invalidManifest("Unknown audio subcommand: \(subcommand)")
        }
    }

    private static func listTTSModels() {
        for model in TTSMLX.supportedModels {
            let voices = model.suggestedVoices.map(\.identifier).joined(separator: ",")
            let languages = model.supportedLanguages.map(\.identifier).joined(separator: ",")
            print("\(model.id)\t\(model.displayName)\tvoices: \(voices.isEmpty ? "-" : voices)\tlanguages: \(languages.isEmpty ? "-" : languages)")
        }
    }

    private static func speak(arguments: [String], currentDirectoryURL: URL) async throws {
        let options = try SpeakOptions(arguments: arguments, currentDirectoryURL: currentDirectoryURL)
        let outputURL = try options.outputURL ?? defaultOutputURL(currentDirectoryURL: currentDirectoryURL)

        if FileManager.default.fileExists(atPath: outputURL.path), !options.forceOverwrite {
            throw StoreError.invalidManifest("Output file already exists at \(outputURL.path). Re-run with --force to overwrite it.")
        }

        let result = try await AudioSpeechGenerator.synthesize(
            .init(
                text: options.text,
                model: options.model,
                voice: options.voice,
                language: options.language,
                outputURL: outputURL,
                forceOverwrite: options.forceOverwrite,
                profile: options.profile,
                maxTokens: options.maxTokens,
                temperature: options.temperature,
                topP: options.topP,
                hfToken: options.hfToken
            ),
            currentDirectoryURL: currentDirectoryURL,
            progressHandler: { update in
                renderProgress(update)
            }
        )

        print("Saved audio: \(result.url.path)")
        print("Model: \(result.modelID)")
        print("Sample rate: \(result.sampleRate) Hz")

        if options.play {
            try playAudio(at: result.url)
        }
    }

    private static func renderProgress(_ update: TTSProgressUpdate) {
        if let fraction = update.fractionCompleted {
            let percent = Int((fraction * 100).rounded())
            print("[\(update.stage.rawValue)] \(percent)% \(update.message)")
        } else {
            print("[\(update.stage.rawValue)] \(update.message)")
        }
    }

    private static func defaultOutputURL(currentDirectoryURL: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = currentDirectoryURL.appendingPathComponent(".esh/audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(formatter.string(from: Date())).wav")
    }

    private static func playAudio(at url: URL) throws {
        let output = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/afplay"),
            arguments: [url.path]
        )
        guard output.exitCode == 0 else {
            let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
            throw StoreError.invalidManifest("afplay failed: \(stderr)")
        }
    }

    private struct SpeakOptions {
        var text: String = ""
        var model: String?
        var voice: String?
        var language: String?
        var outputURL: URL?
        var play: Bool = false
        var forceOverwrite: Bool = false
        var profile: TTSGenerationProfile?
        var maxTokens: Int?
        var temperature: Float?
        var topP: Float?
        var hfToken: String?

        init(arguments: [String], currentDirectoryURL: URL) throws {
            var positional: [String] = []
            var index = 0

            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--model":
                    model = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                case "--voice":
                    voice = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                case "--language":
                    language = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                case "--out":
                    let value = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                    outputURL = Self.resolvePath(value, currentDirectoryURL: currentDirectoryURL)
                case "--text-file":
                    let value = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                    let url = Self.resolvePath(value, currentDirectoryURL: currentDirectoryURL)
                    text = try String(contentsOf: url, encoding: .utf8)
                case "--profile":
                    let value = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                    guard let parsed = TTSGenerationProfile(rawValue: value) else {
                        throw StoreError.invalidManifest("Unknown TTS profile \(value). Use fast, balanced, or highQuality.")
                    }
                    profile = parsed
                case "--max-tokens":
                    let value = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                    guard let parsed = Int(value) else {
                        throw StoreError.invalidManifest("--max-tokens must be an integer.")
                    }
                    maxTokens = parsed
                case "--temperature":
                    let value = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                    guard let parsed = Float(value) else {
                        throw StoreError.invalidManifest("--temperature must be a number.")
                    }
                    temperature = parsed
                case "--top-p":
                    let value = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                    guard let parsed = Float(value) else {
                        throw StoreError.invalidManifest("--top-p must be a number.")
                    }
                    topP = parsed
                case "--hf-token":
                    hfToken = try Self.requiredValue(after: argument, arguments: arguments, index: &index)
                case "--play":
                    play = true
                case "--force":
                    forceOverwrite = true
                default:
                    if argument.hasPrefix("--") {
                        throw StoreError.invalidManifest("Unknown audio speak option \(argument).")
                    }
                    positional.append(argument)
                }
                index += 1
            }

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = positional.joined(separator: " ")
            }

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw StoreError.invalidManifest("Usage: esh audio speak <text> [--model <id>] [--voice <id>] [--language <name>] [--out <path>] [--play] [--force]")
            }
        }

        private static func requiredValue(after flag: String, arguments: [String], index: inout Int) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw StoreError.invalidManifest("Missing value for \(flag).")
            }
            return arguments[index]
        }

        private static func resolvePath(_ path: String, currentDirectoryURL: URL) -> URL {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded)
            }
            return currentDirectoryURL.appendingPathComponent(expanded)
        }
    }
}
