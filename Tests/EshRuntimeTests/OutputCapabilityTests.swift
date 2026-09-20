import Foundation
import Testing
import EshCore
@testable import EshRuntime

// rc.22 A — capability discovery of multi-output support, so a consumer never hardcodes model knowledge.

private struct MultiProvider: CapabilityProvider {
    let descriptor: CapabilityProviderDescriptor
    init(id: String, capability: CapabilityID, maxCount: Int) {
        descriptor = CapabilityProviderDescriptor(id: id, capabilities: [capability], acceptedInputs: [.text],
            producedOutputs: [.image], backend: .mlx, streaming: true,
            supportsMultipleOutputs: maxCount > 1, maximumOutputCount: maxCount)
    }
    func execute(_ r: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite struct OutputCapabilityTests {
    private func runtime(_ providers: [any CapabilityProvider]) async -> EshRuntime {
        let rt = EshRuntime(registry: InferenceBackendRegistry(backends: [:]))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-oc-\(UUID().uuidString)", isDirectory: true)
        let root = PersistenceRoot(rootURL: dir)
        var reg = CapabilityRegistry()
        for p in providers { reg.register(p) }
        let svc = CapabilityExecutionService(registry: reg,
            context: ExecutionContext(root: root, artifactStore: FileArtifactStore(rootURL: root.artifactsURL)))
        await rt.attachCapabilities(service: svc, registry: reg, root: root)
        return rt
    }

    @Test func reportsMultiOutputSupportAndMax() async {
        let rt = await runtime([MultiProvider(id: "gen", capability: .imageGenerate, maxCount: 4)])
        let info = await rt.outputCapability(for: .imageGenerate)
        #expect(info.supportsMultiple)
        #expect(info.maxCount == 4)
    }

    @Test func singleOutputCapabilityReportsOne() async {
        let rt = await runtime([MultiProvider(id: "edit", capability: .imageEdit, maxCount: 1)])
        let info = await rt.outputCapability(for: .imageEdit)
        #expect(!info.supportsMultiple)
        #expect(info.maxCount == 1)
    }

    @Test func unknownCapabilityDefaultsToOne() async {
        let rt = await runtime([])
        let info = await rt.outputCapability(for: .musicGenerate)
        #expect(!info.supportsMultiple && info.maxCount == 1)
    }
}
