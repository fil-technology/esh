import Foundation
import EshCore

enum ModelRemoveCommand {
    static func run(modelID: String, service: ModelService) throws {
        let resolvedID = try ModelInspectCommand.resolveModelID(identifier: modelID, service: service)
        try service.remove(id: resolvedID)
        print("Removed \(resolvedID)")
    }
}
