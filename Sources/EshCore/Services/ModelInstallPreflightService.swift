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

            // Memory sufficiency is assessed (and soft-gated) by ModelFitService as a fit class;
            // it is NOT a hard block here. Knowledgeable users may deliberately try a model esh
            // predicts will be tight. Only genuine technical incompatibility (below) blocks.
            if memory.totalBytes < requirement {
                report.warnings.append(
                    "This Mac has \(ByteFormatting.string(for: memory.totalBytes)) unified memory; ~\(ByteFormatting.string(for: requirement)) is recommended — expect heavy memory pressure."
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
                    // Soft gate: surfaced by ModelFitService (diskSufficient=false) and confirmed
                    // by the install command, not hard-blocked here.
                    report.warnings.append(
                        "Target storage has \(ByteFormatting.string(for: storage.availableBytes)) free but ~\(ByteFormatting.string(for: diskRequirement)) is needed for \(repoID)."
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
            case .unsupportedFormat, .unsupportedArchitecture:
                // Genuine technical incompatibility -> the only hard block.
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
            case .insufficientMemory:
                // Not a hard block — memory is a soft fit gate. Surface as a warning.
                report.warnings.append("Runtime compatibility check flags \(repoID) as memory-heavy for this Mac (verdict: insufficientMemory).")
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
