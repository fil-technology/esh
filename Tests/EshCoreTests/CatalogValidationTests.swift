import Foundation
import Testing
@testable import EshCore

@Suite
struct CatalogValidationTests {
    private let registry = RecommendedModelRegistry()
    private var models: [RecommendedModel] { RecommendedModelRegistry.defaultModels }

    @Test
    func everyEntryIsWellFormed() {
        for model in models {
            #expect(!model.id.isEmpty, "empty id")
            #expect(!model.repoID.isEmpty, "empty repoID for \(model.id)")
            #expect(!model.title.isEmpty, "empty title for \(model.id)")
            #expect(!model.capabilities.isEmpty, "\(model.id) declares no capabilities")
            #expect(model.estimatedMemoryGB > 0, "\(model.id) has non-positive memory")
            #expect(model.totalDiskSizeGB > 0, "\(model.id) has non-positive disk")
            if let ctx = model.contextWindow {
                #expect(ctx > 0, "\(model.id) has non-positive context window")
            }
        }
    }

    @Test
    func aliasesAndSortOrdersAreUnique() {
        let ids = models.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate alias ids")
        let orders = models.map(\.sortOrder)
        #expect(Set(orders).count == orders.count, "duplicate sortOrders")
    }

    @Test
    func ggufEntriesUseGGUFBackend() {
        for model in models where model.id.hasSuffix("-gguf") {
            #expect(model.backend == .gguf, "\(model.id) should be a GGUF backend")
        }
    }

    @Test
    func chatCapableEntriesExist() {
        #expect(models.contains { $0.capabilities.contains(.chat) })
        #expect(models.contains { $0.capabilities.contains(.coding) })
        #expect(models.contains { $0.capabilities.contains(.reasoning) })
    }

    @Test
    func recommendRespectsMemoryBudget() {
        let host = HostMachineProfile(totalMemoryGB: 8, availableMemoryGB: 6, safeBudgetGB: 3.0)
        let recommended = registry.recommend(useCase: .general, host: host, limit: 10)
        #expect(!recommended.isEmpty)
        for model in recommended {
            #expect(model.estimatedMemoryGB <= 3.0, "\(model.id) exceeds the 3GB budget")
        }
    }

    @Test
    func recommendExcludesExperimentalByDefault() {
        let all = registry.recommend(useCase: .general, host: nil, limit: 100)
        #expect(all.allSatisfy { $0.status != .experimental && $0.status != .incompatible })
        let withExperimental = registry.recommend(useCase: .general, host: nil, limit: 100, includeExperimental: true)
        #expect(withExperimental.count >= all.count)
    }

    @Test
    func codingProfileReturnsCodingModels() {
        let coding = registry.recommend(useCase: .coding, host: nil, limit: 5)
        #expect(!coding.isEmpty)
        #expect(coding.allSatisfy { $0.capabilities.contains(.coding) })
    }

    /// Opt-in live verification that every catalog repo actually resolves on Hugging Face and has
    /// the expected on-disk format. Skipped unless ESH_LIVE_HF_TESTS=1 (keeps CI offline/fast).
    @Test
    func liveCatalogReposResolveOnHuggingFace() async throws {
        guard ProcessInfo.processInfo.environment["ESH_LIVE_HF_TESTS"] == "1" else { return }
        for model in models {
            guard let url = URL(string: "https://huggingface.co/api/models/\(model.repoID)") else {
                Issue.record("bad repo URL for \(model.id)")
                continue
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            #expect(code == 200, "\(model.repoID) returned HTTP \(code)")
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let siblings = (json?["siblings"] as? [[String: Any]]) ?? []
            let names = siblings.compactMap { $0["rfilename"] as? String }
            if model.backend == .gguf {
                #expect(names.contains { $0.hasSuffix(".gguf") }, "\(model.repoID) has no .gguf files")
            } else {
                #expect(names.contains { $0.hasSuffix(".safetensors") }, "\(model.repoID) has no safetensors")
                #expect(names.contains("config.json"), "\(model.repoID) has no config.json")
            }
        }
    }
}
