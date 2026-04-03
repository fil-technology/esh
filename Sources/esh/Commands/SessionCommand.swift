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
        case "grep":
            guard let query = arguments.dropFirst().first, !query.isEmpty else {
                throw StoreError.invalidManifest("Usage: esh session grep <text>")
            }
            try grep(query: query, store: store)
        case "show":
            guard let identifier = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: esh session show <uuid-or-name>")
            }
            let session = try CommandSupport.resolveSession(identifier: identifier, sessionStore: store)
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

    private static func grep(query: String, store: SessionStore) throws {
        let sessions = try store.listSessions()
        let lowered = query.lowercased()
        var didMatch = false

        for session in sessions {
            for message in session.messages where message.text.lowercased().contains(lowered) {
                didMatch = true
                print("\(session.name)\t\(session.id.uuidString)\t\(message.role.rawValue): \(message.text)")
            }
        }

        if !didMatch {
            print("No matching session messages.")
        }
    }
}
