import Foundation
import EshCore

/// `esh model info <model>` — show catalog/install metadata for a model.
///
/// Resolves a recommended-catalog alias first (rich metadata: context window, capabilities,
/// RAM/disk, status), then an installed model. For an arbitrary Hugging Face repo, points the user
/// at `esh model check` / `esh model compatibility`.
enum ModelInfoCommand {
    static func run(identifier: String, service: ModelService) throws {
        if let model = service.resolveRecommended(alias: identifier) {
            printRecommended(model)
            return
        }
        if let install = try service.list().first(where: { $0.id == identifier || $0.spec.source.reference == identifier }) {
            printInstall(install)
            return
        }
        print("No catalog entry or installed model matches '\(identifier)'.")
        print("For an arbitrary Hugging Face repo, run: esh model check \(identifier)")
    }

    private static func printRecommended(_ model: RecommendedModel) {
        print("\(model.title)  [\(model.status.rawValue)]")
        print("  alias:        \(model.id)")
        print("  repo:         \(model.repoID)")
        print("  backend:      \(model.backend.rawValue)")
        print("  parameters:   \(model.parameterSize)")
        print("  quantization: \(model.quantization)")
        print("  context:      \(model.contextHint)")
        print("  capabilities: \(model.capabilities.map(\.rawValue).joined(separator: ", "))")
        print("  memory:       \(model.memoryHint)")
        print("  disk:         \(model.sizeHint)")
        print("  tier:         \(model.tier.displayName)")
        print("  tags:         \(model.tags.joined(separator: ", "))")
        print("  summary:      \(model.summary)")
        if model.status == .experimental {
            print("  note:         experimental — newer runtime/template; verify with `esh model check \(model.repoID)`.")
        }
        print("")
        print("Install: esh model install \(model.id)")
    }

    private static func printInstall(_ install: ModelInstall) {
        print("\(install.id)  [installed]")
        print("  repo:     \(install.spec.source.reference)")
        print("  backend:  \(install.spec.backend.rawValue)")
        print("  size:     \(ByteFormatting.string(for: install.sizeBytes))")
        print("  path:     \(install.installPath)")
        print("")
        print("Compatibility: esh model compatibility \(install.id)")
    }
}
