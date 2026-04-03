import Foundation

public struct PersistenceRoot: Sendable {
    public let rootURL: URL
    public let sessionsURL: URL
    public let cachesURL: URL
    public let modelsURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        self.cachesURL = rootURL.appendingPathComponent("caches", isDirectory: true)
        self.modelsURL = rootURL.appendingPathComponent("models", isDirectory: true)
    }

    public static func `default`() -> PersistenceRoot {
        if let override = ProcessInfo.processInfo.environment["ESH_HOME"] ?? ProcessInfo.processInfo.environment["LLMCACHE_HOME"],
           !override.isEmpty {
            return PersistenceRoot(rootURL: URL(fileURLWithPath: override, isDirectory: true))
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let eshRoot = home.appendingPathComponent(".esh", isDirectory: true)
        let legacyRoot = home.appendingPathComponent(".llmcache", isDirectory: true)

        migrateLegacyRootIfNeeded(
            fileManager: fileManager,
            legacyRoot: legacyRoot,
            eshRoot: eshRoot
        )

        return PersistenceRoot(rootURL: eshRoot)
    }

    private static func migrateLegacyRootIfNeeded(
        fileManager: FileManager,
        legacyRoot: URL,
        eshRoot: URL
    ) {
        guard fileManager.fileExists(atPath: legacyRoot.path) else { return }

        if !fileManager.fileExists(atPath: eshRoot.path) {
            try? fileManager.createDirectory(at: eshRoot, withIntermediateDirectories: true)
        }

        for child in ["models", "sessions", "caches"] {
            let legacyChild = legacyRoot.appendingPathComponent(child, isDirectory: true)
            let eshChild = eshRoot.appendingPathComponent(child, isDirectory: true)

            guard fileManager.fileExists(atPath: legacyChild.path) else {
                continue
            }

            if !fileManager.fileExists(atPath: eshChild.path) {
                do {
                    try fileManager.moveItem(at: legacyChild, to: eshChild)
                    continue
                } catch {
                    do {
                        try fileManager.copyItem(at: legacyChild, to: eshChild)
                        continue
                    } catch {
                        continue
                    }
                }
            }

            mergeDirectoryContents(
                fileManager: fileManager,
                sourceDirectory: legacyChild,
                destinationDirectory: eshChild
            )
        }
    }

    private static func mergeDirectoryContents(
        fileManager: FileManager,
        sourceDirectory: URL,
        destinationDirectory: URL
    ) {
        guard let items = try? fileManager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for item in items {
            let destination = destinationDirectory.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    mergeDirectoryContents(
                        fileManager: fileManager,
                        sourceDirectory: item,
                        destinationDirectory: destination
                    )
                }
                continue
            }

            do {
                try fileManager.moveItem(at: item, to: destination)
            } catch {
                do {
                    try fileManager.copyItem(at: item, to: destination)
                } catch {
                    continue
                }
            }
        }
    }
}
