import Foundation

public struct ModelInstallPreflightService: Sendable {
    private let session: URLSession
    private let runtimeValidator: any RemoteModelConfigValidating

    public init(
        session: URLSession = .shared,
        runtimeValidator: any RemoteModelConfigValidating = MLXBackend()
    ) {
        self.session = session
        self.runtimeValidator = runtimeValidator
    }

    public func evaluate(
        repoID: String,
        recommendedModel: RecommendedModel?,
        searchResult: ModelSearchResult?
    ) async throws -> ModelInstallPreflightReport {
        var report = ModelInstallPreflightReport()

        if let requirement = ModelMemoryAdvisor.requiredMemoryBytes(
            recommendedModel: recommendedModel,
            searchResult: searchResult
        ), let memory = SystemMemory.snapshot() {
            report.notes.append(
                "Unified memory needed: \(ByteFormatting.string(for: requirement))"
            )
            report.notes.append(
                "This Mac: \(ByteFormatting.string(for: memory.totalBytes)) total, \(ByteFormatting.string(for: memory.availableBytes)) available now"
            )

            if memory.totalBytes < requirement {
                report.blockers.append(
                    """
                    Not enough unified memory for \(repoID).
                    Recommended: \(ByteFormatting.string(for: requirement))
                    This Mac: \(ByteFormatting.string(for: memory.totalBytes)) total
                    """
                )
            } else if memory.availableBytes < requirement {
                report.blockers.append(
                    """
                    Not enough available memory to start downloading \(repoID).
                    Recommended free memory: \(ByteFormatting.string(for: requirement))
                    Available now: \(ByteFormatting.string(for: memory.availableBytes))
                    """
                )
            }
        }

        if let diskRequirement = ModelMemoryAdvisor.requiredDiskBytes(
            recommendedModel: recommendedModel,
            searchResult: searchResult
        ) {
            report.notes.append(
                "Free disk needed: \(ByteFormatting.string(for: diskRequirement))"
            )

            if let storage = SystemStorage.snapshot(at: PersistenceRoot.default().modelsURL) {
                report.notes.append(
                    "Available disk: \(ByteFormatting.string(for: storage.availableBytes))"
                )
                if storage.availableBytes < diskRequirement {
                    report.blockers.append(
                        """
                        Not enough disk space to download \(repoID).
                        Required free space: \(ByteFormatting.string(for: diskRequirement))
                        Available now: \(ByteFormatting.string(for: storage.availableBytes))
                        """
                    )
                }
            } else {
                report.warnings.append(
                    "Could not verify free disk space automatically. Estimated required free space: \(ByteFormatting.string(for: diskRequirement))."
                )
            }
        }

        do {
            if let configJSON = try await fetchRemoteConfigJSON(repoID: repoID) {
                if let incompatibility = try runtimeValidator.validateRemoteConfig(jsonText: configJSON) {
                    report.blockers.append(
                        """
                        MLX runtime compatibility check failed before download.
                        \(incompatibility)
                        """
                    )
                } else {
                    report.notes.append("MLX runtime compatibility: config check passed before download")
                }
            } else {
                report.warnings.append(
                    "Could not find a remote config.json for \(repoID), so runtime compatibility could not be verified before download."
                )
            }
        } catch {
            report.warnings.append(
                "Could not verify runtime compatibility before download: \(error.localizedDescription)"
            )
        }

        return report
    }

    private func fetchRemoteConfigJSON(repoID: String) async throws -> String? {
        var url = URL(string: "https://huggingface.co")!
        for component in repoID.split(separator: "/").map(String.init) {
            url.append(path: component)
        }
        url.append(path: "raw")
        url.append(path: "main")
        url.append(path: "config.json")

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                return String(decoding: data, as: UTF8.self)
            case 404:
                return nil
            default:
                throw StoreError.invalidManifest("Failed to fetch remote config: HTTP \(http.statusCode).")
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
