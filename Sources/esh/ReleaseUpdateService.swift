import Foundation
import EshCore

struct ReleaseUpdateNotice: Equatable {
    let currentVersion: String
    let latestVersion: String
    let upgradeCommand: String
}

struct ReleaseUpdateService {
    private struct CacheRecord: Codable {
        let checkedAt: Date
        let latestVersion: String
    }

    private struct LatestReleaseResponse: Codable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    private let session: URLSession
    private let persistenceRoot: PersistenceRoot
    private let now: @Sendable () -> Date

    init(
        session: URLSession = .shared,
        persistenceRoot: PersistenceRoot = .default(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.persistenceRoot = persistenceRoot
        self.now = now
    }

    func checkForUpdate() async -> ReleaseUpdateNotice? {
        guard let currentVersion = AppVersionResolver.currentVersion() else {
            return nil
        }

        guard let latestVersion = await latestKnownVersion() else {
            return nil
        }
        guard compareSemver(currentVersion, latestVersion) == .orderedAscending else {
            return nil
        }

        return ReleaseUpdateNotice(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            upgradeCommand: "brew upgrade --cask esh"
        )
    }

    private func latestKnownVersion() async -> String? {
        if let cached = loadCache(),
           now().timeIntervalSince(cached.checkedAt) < 60 * 60 * 12 {
            return cached.latestVersion
        }

        if let fetched = await fetchLatestVersion() {
            saveCache(CacheRecord(checkedAt: now(), latestVersion: fetched))
            return fetched
        }

        return loadCache()?.latestVersion
    }

    private func fetchLatestVersion() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/fil-technology/esh/releases/latest") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("esh-cli", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            let payload = try JSONDecoder().decode(LatestReleaseResponse.self, from: data)
            return normalizedVersion(fromTag: payload.tagName)
        } catch {
            return nil
        }
    }

    private func normalizedVersion(fromTag tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        return compareSemver(version, version) == .orderedSame ? version : nil
    }

    private func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        func parse(_ value: String) -> [Int]? {
            let parts = value.split(separator: ".")
            guard parts.count == 3 else { return nil }
            let numbers = parts.compactMap { Int($0) }
            return numbers.count == 3 ? numbers : nil
        }

        guard let left = parse(lhs), let right = parse(rhs) else {
            return nil
        }

        for (l, r) in zip(left, right) {
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private func loadCache() -> CacheRecord? {
        let url = cacheURL
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(CacheRecord.self, from: data)
    }

    private func saveCache(_ record: CacheRecord) {
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else {
            return
        }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var cacheURL: URL {
        persistenceRoot.rootURL
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("release-update.json")
    }
}

enum AppVersionResolver {
    static func currentVersion() -> String? {
        if let version = ProcessInfo.processInfo.environment["ESH_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return version
        }

        for candidate in candidateVersionFileURLs() {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else {
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSemver(trimmed) {
                return trimmed
            }
        }

        return nil
    }

    private static func candidateVersionFileURLs() -> [URL] {
        var urls: [URL] = []
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var current = executable.deletingLastPathComponent()

        while true {
            urls.append(current.appendingPathComponent("VERSION"))
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        if let packagedRoot = packagedRootURL() {
            urls.append(packagedRoot.appendingPathComponent("VERSION"))
            urls.append(packagedRoot.appendingPathComponent("share/esh/VERSION"))
        }

        return urls
    }

    private static func packagedRootURL() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binDirectory = executable.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else {
            return nil
        }
        return binDirectory.deletingLastPathComponent()
    }

    private static func isSemver(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { Int($0) != nil }
    }
}
