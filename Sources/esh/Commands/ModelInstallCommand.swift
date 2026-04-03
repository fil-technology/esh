import Foundation
import EshCore

enum ModelInstallCommand {
    static func run(repoID: String, service: ModelService) async throws {
        let manifest = try await service.install(repoID: repoID) { state in
            DownloadProgressView.render(state: state)
        }
        print("Installed \(manifest.install.id) at \(manifest.install.installPath)")
    }
}
