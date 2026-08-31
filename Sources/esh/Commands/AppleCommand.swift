import Foundation
import EshCore

/// `esh apple` — use Apple Foundation Models (Apple Intelligence) on-device, with zero model
/// downloads. Distinct from esh-managed MLX/GGUF models; never silently used in their place.
///
///   esh apple status [--json]
///   esh apple <prompt> [--system <instructions>]
enum AppleCommand {
    static func run(arguments: [String]) async throws {
        let service = AppleIntelligenceService()
        let sub = arguments.first ?? "status"

        if sub == "status" {
            let status = service.status()
            if arguments.contains("--json") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(status), let text = String(data: data, encoding: .utf8) { print(text) }
            } else {
                print("apple intelligence: \(status.available ? "available" : status.availability.rawValue)")
                print("  \(status.detail)")
                print("  execution: on-device (not Private Cloud Compute)")
                if let fix = status.suggestedFix { print("  fix: \(fix)") }
            }
            return
        }

        // Treat everything else as a prompt.
        let system = CommandSupport.optionalValue(flag: "--system", in: arguments)
        let prompt = CommandSupport.positionalArguments(in: arguments, knownFlags: ["--system"])
            .filter { !$0.hasPrefix("--") }
            .joined(separator: " ")
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalidManifest("Usage: esh apple <prompt> [--system <instructions>]  |  esh apple status")
        }
        do {
            let output = try await service.generate(prompt: prompt, instructions: system)
            print(output)
        } catch {
            throw StoreError.invalidManifest(error.localizedDescription)
        }
    }
}
