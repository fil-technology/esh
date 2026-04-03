import Foundation
import EshCore

enum SessionCommand {
    static func run(arguments: [String], store: SessionStore) throws {
        guard let subcommand = arguments.first else {
            try list(store: store)
            return
        }

        switch subcommand {
        case "list":
            try list(store: store)
        case "show":
            guard let rawID = arguments.dropFirst().first, let id = UUID(uuidString: rawID) else {
                throw StoreError.invalidManifest("Usage: esh session show <uuid>")
            }
            let session = try store.loadSession(id: id)
            print("name: \(session.name)")
            print("messages: \(session.messages.count)")
            for message in session.messages {
                print("\(message.role.rawValue): \(message.text)")
            }
        default:
            throw StoreError.invalidManifest("Unknown session subcommand: \(subcommand)")
        }
    }

    private static func list(store: SessionStore) throws {
        let sessions = try store.listSessions()
        if sessions.isEmpty {
            print("No saved sessions.")
            return
        }
        for session in sessions {
            print("\(session.id.uuidString)\t\(session.name)\t\(session.messages.count) messages")
        }
    }
}
