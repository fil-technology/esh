import Foundation
import Testing
@testable import EshCore

// rc.22 A — multi-output / variants. Deterministic: a mock provider that emits N artifacts with variant
// provenance, driven through the real CapabilityExecutionService (which clamps outputCount). No MLX.

private final class MockVariantProvider: CapabilityProvider, @unchecked Sendable {
    let descriptor: CapabilityProviderDescriptor
    init(id: String = "mock-variant", maxCount: Int) {
        descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.imageGenerate], acceptedInputs: [.text], producedOutputs: [.image],
            backend: .mlx, streaming: true, supportsMultipleOutputs: maxCount > 1, maximumOutputCount: maxCount)
    }
    func execute(_ r: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let n = max(1, r.request.outputCount ?? 1)
        var base: UInt64 = 0
        if case .int(let s)? = r.request.options.values["seed"] { base = UInt64(bitPattern: Int64(s)) }
        let batchID = UUID()
        let store = context.artifactStore
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            for i in 0 ..< n {
                let seed = VariantSeed.derive(base: base, index: i)
                let art = Artifact(kind: .image, mimeType: "image/png", files: [], entrypoint: "v.png",
                                   generatedBy: ArtifactProvenance(providerID: providerID, capability: .imageGenerate,
                                                                   batchID: batchID, variantIndex: i, seed: seed))
                if let saved = try? store.save(art, files: ["v.png": Data([UInt8(i & 0xFF)])]) {
                    cont.yield(.artifactProduced(saved))
                }
            }
            cont.yield(.done(finishReason: "stop")); cont.finish()
        }
    }
}

@Suite struct MultiOutputTests {
    private func service(_ provider: any CapabilityProvider) -> (CapabilityExecutionService, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-mo-\(UUID().uuidString)", isDirectory: true)
        let ctx = ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                   artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts")))
        return (CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx), dir)
    }
    private func req(outputCount: Int?, seed: Int? = 1000) -> ExecutionRequest {
        var opts: [String: JSONValue] = [:]
        if let seed { opts["seed"] = .int(seed) }
        return ExecutionRequest(capability: .imageGenerate, inputs: [.text("a cat")],
                                output: OutputSpec(modality: .image, format: "image/png"),
                                options: ExecutionOptions(opts), outputCount: outputCount)
    }

    @Test func outputCountClampedToProviderMaximum() async throws {
        let (svc, dir) = service(MockVariantProvider(maxCount: 3)); defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await svc.executeCollecting(req(outputCount: 10))
        #expect(result.outputs.count == 3)   // 10 clamped to maxCount 3
    }

    @Test func sharedBatchIDDistinctVariantIndexAndRecordedSeeds() async throws {
        let (svc, dir) = service(MockVariantProvider(maxCount: 4)); defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await svc.executeCollecting(req(outputCount: 4, seed: 1000))
        #expect(result.outputs.count == 4)
        let batchIDs = Set(result.outputs.map { $0.generatedBy.batchID })
        #expect(batchIDs.count == 1 && batchIDs.first! != nil)                 // one batchID for the execution
        #expect(result.outputs.map { $0.generatedBy.variantIndex } == [0, 1, 2, 3])
        // Each output records its ACTUAL derived seed.
        let base = UInt64(bitPattern: 1000)
        #expect(result.outputs.map { $0.generatedBy.seed } == (0..<4).map { VariantSeed.derive(base: base, index: $0) })
        #expect(result.outputs[0].generatedBy.seed == base)                    // variant 0 == base seed
    }

    @Test func singleOutputProviderIgnoresHigherCount() async throws {
        let (svc, dir) = service(MockVariantProvider(maxCount: 1)); defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await svc.executeCollecting(req(outputCount: 5))
        #expect(result.outputs.count == 1)   // honest single-output cap
    }

    @Test func nilOutputCountIsSingleOutputAndBackwardCompatible() async throws {
        let (svc, dir) = service(MockVariantProvider(maxCount: 4)); defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await svc.executeCollecting(req(outputCount: nil))
        #expect(result.outputs.count == 1)
        #expect(result.outputs[0].generatedBy.variantIndex == 0)
    }

    @Test func artifactsStreamIncrementally() async throws {
        let (svc, dir) = service(MockVariantProvider(maxCount: 3)); defer { try? FileManager.default.removeItem(at: dir) }
        var count = 0
        for try await ev in svc.execute(req(outputCount: 3)) {
            if case .artifactProduced = ev { count += 1 }
        }
        #expect(count == 3)   // one .artifactProduced per variant, streamed
    }
}

@Suite struct VariantSeedTests {
    @Test func indexZeroReturnsBase() {
        #expect(VariantSeed.derive(base: 12345, index: 0) == 12345)
    }
    @Test func distinctAndDeterministic() {
        let a = VariantSeed.batch(base: 42, count: 5)
        let b = VariantSeed.batch(base: 42, count: 5)
        #expect(a == b)                        // deterministic
        #expect(Set(a).count == 5)             // distinct
        #expect(a[0] == 42)                     // first == base
    }
    @Test func differentBasesDiffer() {
        #expect(VariantSeed.derive(base: 1, index: 1) != VariantSeed.derive(base: 2, index: 1))
    }
}
