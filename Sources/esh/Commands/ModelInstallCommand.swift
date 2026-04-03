import Foundation
import EshCore

enum ModelInstallCommand {
    static func run(identifier: String, service: ModelService, registry: RecommendedModelRegistry) async throws {
        let resolved = registry.resolve(alias: identifier)
        let repoID = resolved?.repoID ?? identifier
        let manifest = try await service.install(repoID: repoID) { state in
            DownloadProgressView.render(state: state)
        }
        if let resolved {
            print("Installed \(resolved.id) (\(manifest.install.id)) at \(manifest.install.installPath)")
        } else {
            print("Installed \(manifest.install.id) at \(manifest.install.installPath)")
        }
    }
}
