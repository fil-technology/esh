import Foundation
import EshCore

enum ModelListCommand {
    static func run(service: ModelService) {
        do {
            let installs = try service.list()
            if installs.isEmpty {
                print("No installed models.")
                return
            }
            for install in installs {
                print("\(install.id)\t\(ByteFormatting.string(for: install.sizeBytes))\t\(install.installPath)")
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
        }
    }
}
