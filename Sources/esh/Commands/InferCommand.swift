import Foundation
import EshCore

enum InferCommand {
    static func run(arguments: [String], root: PersistenceRoot) async throws {
        let request = try resolveRequest(arguments: arguments)
        let service = ExternalInferenceService(
            modelStore: FileModelStore(root: root),
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root)
        )
        let response = try await service.infer(request: request)
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
            "--cache-mode",
            "--intent",
            "--session-name"
        ]
        let positional = CommandSupport.positionalArguments(in: arguments, knownFlags: knownFlags)
            .filter { !$0.hasPrefix("--") }
        let positionalMessage = positional.first

        let message = CommandSupport.optionalValue(flag: "--message", in: arguments) ?? positionalMessage
        guard let message, message.isEmpty == false else {
            throw StoreError.invalidManifest(
                "Usage: esh infer --input <path-or-> | esh infer --model <id-or-repo> --message <text> [--system <text>] [--artifact <uuid>] [--max-tokens N] [--temperature T] [--cache-mode raw|turbo|triattention|auto] [--intent chat|code|documentqa|agentrun|multimodal] [--session-name <name>]"
            )
        }

        let systemPrompt = CommandSupport.optionalValue(flag: "--system", in: arguments)
        let model = CommandSupport.optionalValue(flag: "--model", in: arguments)
        let artifactValue = CommandSupport.optionalValue(flag: "--artifact", in: arguments)
        let cacheModeValue = CommandSupport.optionalValue(flag: "--cache-mode", in: arguments)
        let intentValue = CommandSupport.optionalValue(flag: "--intent", in: arguments)
        let sessionName = CommandSupport.optionalValue(flag: "--session-name", in: arguments)
        let maxTokens = Int(CommandSupport.optionalValue(flag: "--max-tokens", in: arguments) ?? "") ?? GenerationConfig().maxTokens
        let temperature = Double(CommandSupport.optionalValue(flag: "--temperature", in: arguments) ?? "") ?? GenerationConfig().temperature

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

        return ExternalInferenceRequest(
            model: model,
            cacheArtifactID: cacheArtifactID,
            sessionName: sessionName,
            cacheMode: cacheMode,
            intent: intent,
            messages: messages,
            generation: GenerationConfig(maxTokens: maxTokens, temperature: temperature)
        )
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
}
