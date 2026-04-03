import Foundation
import EshCore

enum CommandSupport {
    static func optionalValue(flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static func requiredValue(flag: String, in arguments: [String]) throws -> String {
        guard let value = optionalValue(flag: flag, in: arguments) else {
            throw StoreError.invalidManifest("Missing required flag \(flag)")
        }
        return value
    }

    static func positionalArguments(in arguments: [String], knownFlags: Set<String>) -> [String] {
        var result: [String] = []
        var iterator = arguments.makeIterator()
        while let item = iterator.next() {
            if knownFlags.contains(item) {
                _ = iterator.next()
                continue
            }
            result.append(item)
        }
        return result
    }

    static func resolveSession(identifier: String, sessionStore: SessionStore) throws -> ChatSession {
        if let id = UUID(uuidString: identifier) {
            return try sessionStore.loadSession(id: id)
        }

        let sessions = try sessionStore.listSessions()
        if let exact = sessions.first(where: { $0.name == identifier }) {
            return exact
        }
        if let caseInsensitive = sessions.first(where: { $0.name.caseInsensitiveCompare(identifier) == .orderedSame }) {
            return caseInsensitive
        }

        throw StoreError.notFound("Session \(identifier) was not found.")
    }

    static func resolveInstall(
        identifier: String?,
        modelStore: FileModelStore,
        preferredModelID: String? = nil
    ) throws -> ModelInstall {
        let installs = try modelStore.listInstalls()
        guard !installs.isEmpty else {
            throw StoreError.notFound("No installed models found.")
        }

        if let identifier, let resolved = resolveInstall(identifier: identifier, installs: installs) {
            return resolved
        }

        if let preferredModelID, let resolved = resolveInstall(identifier: preferredModelID, installs: installs) {
            return resolved
        }

        guard let install = installs.first else {
            throw StoreError.notFound("No installed models found.")
        }
        return install
    }

    static func resolveInstall(identifier: String, installs: [ModelInstall]) -> ModelInstall? {
        if let exact = installs.first(where: { $0.id == identifier }) {
            return exact
        }

        if let byRepo = installs.first(where: { $0.spec.source.reference == identifier }) {
            return byRepo
        }

        if let byDisplayName = installs.first(where: { $0.spec.displayName == identifier }) {
            return byDisplayName
        }

        let lowered = identifier.lowercased()
        return installs.first {
            $0.id.lowercased() == lowered ||
            $0.spec.source.reference.lowercased() == lowered ||
            $0.spec.displayName.lowercased() == lowered
        }
    }

    static func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8))
    }
}
