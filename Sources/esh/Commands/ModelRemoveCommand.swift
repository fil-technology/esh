import Foundation
import EshCore

enum ModelRemoveCommand {
    static func run(modelID: String, service: ModelService) throws {
        try service.remove(id: modelID)
        print("Removed \(modelID)")
    }
}
