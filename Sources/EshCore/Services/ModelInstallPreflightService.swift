import Foundation

public struct ModelInstallPreflightService: Sendable {
    private let session: URLSession
    private let modelCheckService: ModelCheckService

    public init(
        session: URLSession = .shared,
        modelCheckService: ModelCheckService? = nil
    ) {
        self.session = session
        self.modelCheckService = modelCheckService ?? ModelCheckService(
            metadataInspector: ModelMetadataInspector(session: session, retryPolicy: .default)
        )
    }

    public func evaluate(
        repoID: String,
        recommendedModel: RecommendedModel?,
        searchResult: ModelSearchResult?,
        variant: String? = nil,
        forceUnsupportedRuntime: Bool = false
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
            let check = try await modelCheckService.evaluate(repoID: repoID, variant: variant)
            report.notes.append("Backend check: \(check.backendLabel)")
            report.notes.append("Compatibility verdict: \(check.verdict.rawValue)")
            report.notes.append(contentsOf: check.notes)
            report.warnings.append(contentsOf: check.warnings)

            switch check.verdict {
            case .unsupportedFormat, .unsupportedArchitecture, .insufficientMemory:
                let message = """
                Pre-download compatibility check failed for \(repoID).
                Verdict: \(check.verdict.rawValue)
                """
                if forceUnsupportedRuntime {
                    report.warnings.append(
                        "Force install requested; proceeding despite runtime compatibility verdict \(check.verdict.rawValue)."
                    )
                    report.notes.append(message)
                } else {
                    report.blockers.append(message)
                }
            case .unknown where check.backend == nil:
                report.warnings.append("Could not resolve a backend confidently before download.")
            default:
                break
            }
        } catch {
            report.warnings.append(
                "Could not verify runtime compatibility before download: \(error.localizedDescription)"
            )
        }

        return report
    }
}
