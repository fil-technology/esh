import Foundation
import Testing
@testable import EshCore

// Integration of resource-aware selection into CapabilityExecutionService: two profiled providers for the
// same capability, an injected synthetic host + provider-state, verifying Auto picks the best fit, gates
// cleanly (typed) when nothing fits, honors an explicit pin, and prepends the routing rationale as status.

private struct ProfiledMockProvider: CapabilityProvider {
    let descriptor: CapabilityProviderDescriptor
    init(id: String, family: String?, profile: CapabilityResourceProfile) {
        descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.imageEdit], acceptedInputs: [.image, .text], producedOutputs: [.image],
            backend: .mlx, modelFamily: family, streaming: true, resourceProfile: profile)
    }
    func execute(_ r: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { cont in
            // Emit an artifact tagged with THIS provider's id so the test can see which tier ran.
            let art = Artifact(kind: .image, mimeType: "image/png", files: [], entrypoint: "e.png",
                               generatedBy: ArtifactProvenance(providerID: descriptor.id, capability: .imageEdit))
            if let saved = try? context.artifactStore.save(art, files: ["e.png": Data([0x89])]) {
                cont.yield(.artifactProduced(saved))
            }
            cont.yield(.done(finishReason: "stop")); cont.finish()
        }
    }
}

private let gb = 1_073_741_824.0
private let heavy = CapabilityResourceProfile(estimatedPeakMemoryGB: 14, modelDownloadBytes: Int64(10*gb),
    installedBytes: Int64(10*gb), temporaryInstallBytes: Int64(2*gb), minimumSystemVolumeHeadroomGB: 18,
    minimumAssetsVolumeHeadroomGB: 3, qualityTier: 100, latencyClass: .slow)
private let light = CapabilityResourceProfile(estimatedPeakMemoryGB: 8, modelDownloadBytes: Int64(2*gb),
    installedBytes: Int64(2*gb), temporaryInstallBytes: Int64(1*gb), minimumSystemVolumeHeadroomGB: 12,
    minimumAssetsVolumeHeadroomGB: 2, qualityTier: 50, latencyClass: .moderate)

@Suite struct ResourceAwareExecutionTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-rr-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }
    private func registry() -> CapabilityRegistry {
        CapabilityRegistry(providers: [
            ProfiledMockProvider(id: "mlx-instruct-image-edit", family: "instruct-pix2pix", profile: light),
            ProfiledMockProvider(id: "mlx-photomaker-v1", family: "photomaker-v1", profile: heavy)])
    }
    private func editReq(model: String? = nil, constraints: ExecutionConstraints = .default) -> ExecutionRequest {
        ExecutionRequest(capability: .imageEdit,
            inputs: [.attachment(EshAttachment(kind: .image, uri: "file:///x.png")), .text("3d")],
            output: OutputSpec(modality: .image, format: "image/png"), constraints: constraints, model: model)
    }
    private func service(_ host: HostResources, installed: Set<String> = ["mlx-instruct-image-edit", "mlx-photomaker-v1"]) -> (CapabilityExecutionService, URL) {
        let (ctx, dir) = context()
        let svc = CapabilityExecutionService(registry: registry(), context: ctx,
            resourceHost: { host },
            providerState: { id in ProviderRuntimeState(installed: installed.contains(id), warm: false) })
        return (svc, dir)
    }

    private func run(_ svc: CapabilityExecutionService, _ req: ExecutionRequest) async -> (ranProvider: String?, status: [String], error: Error?) {
        var ran: String?; var status: [String] = []
        do {
            for try await ev in svc.execute(req) {
                switch ev {
                case .status(let s): status.append(s)
                case .artifactProduced(let a): ran = a.generatedBy.providerID
                default: break
                }
            }
            return (ran, status, nil)
        } catch { return (ran, status, error) }
    }

    @Test func autoPicksHeavyWhenItFitsAndEmitsRationale() async {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        let (svc, dir) = service(host); defer { try? FileManager.default.removeItem(at: dir) }
        let r = await run(svc, editReq())
        #expect(r.ranProvider == "mlx-photomaker-v1")
        #expect(r.status.contains { $0.contains("mlx-photomaker-v1") && $0.contains("Auto") })
        #expect(r.error == nil)
    }

    @Test func autoFallsBackToLightUnderSwapPressure() async {
        // System volume 14 GB: heavy needs 18 (gated), light needs 12 (fits).
        let host = HostResources(totalMemoryGB: 32, availableMemoryGB: 24, systemVolumeFreeGB: 14, assetsVolumeFreeGB: 600)
        let (svc, dir) = service(host); defer { try? FileManager.default.removeItem(at: dir) }
        let r = await run(svc, editReq())
        #expect(r.ranProvider == "mlx-instruct-image-edit")
    }

    @Test func autoTypedGateWhenNothingFits() async {
        let host = HostResources(totalMemoryGB: 32, availableMemoryGB: 24, systemVolumeFreeGB: 4, assetsVolumeFreeGB: 600)
        let (svc, dir) = service(host); defer { try? FileManager.default.removeItem(at: dir) }
        let r = await run(svc, editReq())
        #expect(r.ranProvider == nil)
        guard case .resourceGated(let gate)? = r.error as? CapabilityError else { Issue.record("expected resourceGated, got \(String(describing: r.error))"); return }
        #expect(!gate.explicit)
    }

    @Test func explicitPinGatedNoSubstitution() async {
        let host = HostResources(totalMemoryGB: 32, availableMemoryGB: 24, systemVolumeFreeGB: 6, assetsVolumeFreeGB: 600)
        let (svc, dir) = service(host); defer { try? FileManager.default.removeItem(at: dir) }
        let r = await run(svc, editReq(model: "mlx-photomaker-v1"))
        #expect(r.ranProvider == nil)   // NOT substituted with the light tier
        guard case .resourceGated(let gate)? = r.error as? CapabilityError else { Issue.record("expected resourceGated"); return }
        #expect(gate.explicit && gate.providerID == "mlx-photomaker-v1")
    }

    @Test func explicitPinRunsWhenItFits() async {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        let (svc, dir) = service(host); defer { try? FileManager.default.removeItem(at: dir) }
        let r = await run(svc, editReq(model: "mlx-photomaker-v1"))
        #expect(r.ranProvider == "mlx-photomaker-v1")
    }

    @Test func offlinePolicyGatesUninstalledButKeepsInstalled() async {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        // Nothing installed + offline → Auto can't download either tier → typed gate.
        let (svc, dir) = service(host, installed: []); defer { try? FileManager.default.removeItem(at: dir) }
        let offline = ExecutionConstraints(allowDownload: false)
        let r = await run(svc, editReq(constraints: offline))
        guard case .resourceGated? = r.error as? CapabilityError else { Issue.record("expected resourceGated"); return }
    }
}
