import Foundation
import Testing
@testable import EshCore

@Suite
struct ImageEditProviderTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-edit-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    private func imageAndText(_ instruction: String, options: [String: JSONValue] = [:]) -> ExecutionRequest {
        ExecutionRequest(
            capability: .imageEdit,
            inputs: [.attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: Data([1,2]).base64EncodedString())),
                     .text(instruction)],
            output: .init(modality: .image),
            options: ExecutionOptions(options))
    }

    @Test
    func producesEditedImageArtifactWithLicenseProvenance() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ImageEditProvider(edit: { _, outPath, instruction, options in
            #expect(instruction == "change the sky to sunset")
            #expect(options.backend == .flux2Klein)   // universal-fit default (Apache-2.0, runs on 32GB)
            #expect(options.loraPaths.isEmpty)          // no adapter requested → LoRA disabled
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outPath))
            return ImageEditResult(width: 1024, height: 1024, backend: "flux2-klein", model: "flux2-klein-4b",
                                   license: "apache-2.0", commercial: true)
        })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(imageAndText("change the sky to sunset"))
        let art = try #require(result.outputs.first)
        #expect(art.kind == .image)
        #expect(art.metadata["license"] == .string("apache-2.0"))
        #expect(art.metadata["commercial"] == .bool(true))
        #expect(art.generatedBy.capability == .imageEdit)
    }

    @Test
    func requiresAnImageAndAnInstruction() async {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ImageEditProvider(edit: { _, _, _, _ in
            ImageEditResult(width: 1, height: 1, backend: "qwen-edit", model: "m", license: "apache-2.0", commercial: true) })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(capability: .imageEdit, inputs: [.text("change the sky")], output: .init(modality: .image)))
        }
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(capability: .imageEdit,
                inputs: [.attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: Data([1]).base64EncodedString()))],
                output: .init(modality: .image)))
        }
    }

    @Test
    func dispatchedForEditImageToImage() {
        let reg = CapabilityRegistry(providers: [ImageEditProvider(edit: { _, _, _, _ in
            ImageEditResult(width: 1, height: 1, backend: "qwen-edit", model: "m", license: "apache-2.0", commercial: true) })])
        #expect(reg.providers(for: .imageEdit, inputs: [.image, .text], output: .image).count == 1)
    }

    // MARK: - Generic LoRA / adapter architecture

    /// Install a fake adapter weight file where the provider looks (image-models/hub/<repo>/snapshots/<rev>/<file>).
    private func installAdapter(_ id: String, into ctx: ExecutionContext) throws -> String {
        let adapter = try #require(ImageAdapterCatalog.resolve(id))
        let dir = ctx.root.cachesURL.appendingPathComponent("image-models/hub/\(adapter.cacheDirName)/snapshots/testrev", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(adapter.file)
        try Data([0x00]).write(to: path)
        return path.path
    }

    @Test
    func neutralAdapterCatalogHasNoBrandNames() {
        // The catalog id/label/aliases must be neutral (no Pixar/Disney branding). Upstream name is provenance only.
        for (id, a) in ImageAdapterCatalog.adapters {
            #expect(!id.lowercased().contains("pixar"))
            #expect(!a.displayName.lowercased().contains("pixar"))
            #expect(!a.displayName.lowercased().contains("disney"))
        }
        let a = ImageAdapterCatalog.resolve("3d-animation")
        #expect(a?.backend == .flux2Klein)        // default 3D style: validated on 32GB, commercial-safe
        #expect(a?.license == "apache-2.0")
        // The high-fidelity variant is the >32GB Qwen path.
        #expect(ImageAdapterCatalog.resolve("3d-animation-max")?.backend == .qwenEdit)
    }

    @Test
    func installedAdapterResolvesToLoRAPathAndBaseModel() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try installAdapter("3d-animation", into: ctx)
        let expectedFile = try #require(ImageAdapterCatalog.resolve("3d-animation")).file
        let provider = ImageEditProvider(edit: { _, outPath, _, options in
            #expect(options.backend == .flux2Klein)                 // adapter dictates the base family (32GB-fitting)
            #expect(options.loraPaths.count == 1)                   // resolved a local LoRA file
            #expect(options.loraPaths.first?.hasSuffix(expectedFile) == true)
            #expect(options.loraScales == [1.0])                    // default scale
            #expect(options.model == nil)                           // uses the flux2-klein backend default weights
            #expect(options.baseModel == nil)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outPath))
            return ImageEditResult(width: 512, height: 512, backend: "flux2-klein", model: "flux2-klein-4b",
                                   license: "apache-2.0", commercial: true)
        })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(imageAndText("Make this a polished 3D animated character",
            options: ["adapter": .string("3d-animation")]))
        let art = try #require(result.outputs.first)
        #expect(art.metadata["adapter"] == .string("3d-animation"))   // provenance records the adapter
    }

    @Test
    func adapterAliasResolves() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try installAdapter("3d-animation", into: ctx)
        let provider = ImageEditProvider(edit: { _, outPath, _, _ in
            try Data([0x89]).write(to: URL(fileURLWithPath: outPath))
            return ImageEditResult(width: 512, height: 512, backend: "qwen-edit", model: "m", license: "apache-2.0", commercial: true)
        })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        // "animated-3d" is an alias → the artifact provenance must record the canonical "3d-animation".
        let result = try await svc.executeCollecting(imageAndText("stylize", options: ["adapter": .string("animated-3d")]))
        let art = try #require(result.outputs.first)
        #expect(art.metadata["adapter"] == .string("3d-animation"))
    }

    @Test
    func unknownAdapterThrows() async {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ImageEditProvider(edit: { _, _, _, _ in
            ImageEditResult(width: 1, height: 1, backend: "qwen-edit", model: "m", license: "apache-2.0", commercial: true) })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(imageAndText("stylize", options: ["adapter": .string("no-such-style")]))
        }
    }

    @Test
    func requestedButNotInstalledAdapterThrows() async {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        // Do NOT install the adapter file → provider must report install-required, not silently ignore it.
        let provider = ImageEditProvider(edit: { _, _, _, _ in
            ImageEditResult(width: 1, height: 1, backend: "qwen-edit", model: "m", license: "apache-2.0", commercial: true) })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(imageAndText("stylize", options: ["adapter": .string("3d-animation")]))
        }
    }

    @Test
    func qualityControlPassesMaxEditSideClampedToRange() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        // The "detailed" tier (1536) flows through as options.maxEditSide; an absurd value is clamped to 2048.
        let provider = ImageEditProvider(edit: { _, outPath, _, options in
            #expect(options.maxEditSide == 1536)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outPath))
            return ImageEditResult(width: 1, height: 1, backend: "flux2-klein", model: "m", license: "apache-2.0", commercial: true)
        })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        _ = try await svc.executeCollecting(imageAndText("stylize", options: ["maxEditSide": .int(1536)]))

        let clamp = ImageEditProvider(edit: { _, outPath, _, options in
            #expect(options.maxEditSide == 2048)   // 9999 clamped down
            try Data([0x89]).write(to: URL(fileURLWithPath: outPath))
            return ImageEditResult(width: 1, height: 1, backend: "flux2-klein", model: "m", license: "apache-2.0", commercial: true)
        })
        let svc2 = CapabilityExecutionService(registry: CapabilityRegistry(providers: [clamp]), context: ctx)
        _ = try await svc2.executeCollecting(imageAndText("stylize", options: ["maxEditSide": .int(9999)]))
    }

    @Test
    func incompatibleBackendPinWithAdapterThrows() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try installAdapter("3d-animation", into: ctx)
        let provider = ImageEditProvider(edit: { _, _, _, _ in
            ImageEditResult(width: 1, height: 1, backend: "qwen-edit", model: "m", license: "apache-2.0", commercial: true) })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        // The 3d-animation adapter is a FLUX.2 Klein LoRA → pinning an incompatible backend (kontext) must error.
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(imageAndText("stylize",
                options: ["adapter": .string("3d-animation"), "backend": .string("kontext")]))
        }
    }

    // MARK: - Model Fit: honest hardware viability

    @Test
    func qwenEditIsNotComfortableOn32GBButKleinIs() {
        let svc = ImageModelFitService()
        let host = HostMachineProfile(chipDescription: "Apple M-test", totalMemoryGB: 32, availableMemoryGB: 20, safeBudgetGB: 24)
        let qwen = svc.assess(input: ImageEditModelFit.input(for: .qwenEdit, width: 1024, height: 1024), host: host, root: PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-fit-\(UUID().uuidString)")))
        #expect(qwen.fitClass == .tight || qwen.fitClass == .unlikely)   // honest: does not comfortably fit 32GB
        #expect(qwen.requiresConfirmation)
        let klein = svc.assess(input: ImageEditModelFit.input(for: .flux2Klein, width: 512, height: 512), host: host, root: PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-fit-\(UUID().uuidString)")))
        #expect(klein.fitClass == .comfortable || klein.fitClass == .fits)
    }

    // MARK: - Tier-0 routing: edit vs segment vs clarify (preserve Router Auto safety)

    private let router = DeterministicIntentRouter()
    private func route(_ msg: String) -> CapabilityIntent { router.route(message: msg, inputModalities: [.image]) }

    @Test func concreteEditInstructionsRouteToImageEdit() {
        for m in ["remove the person on the left", "change the sky to sunset",
                  "replace the red car with a blue one", "make it look like it was taken at night",
                  "extend the image to the left", "change only the shirt color"] {
            let r = router.route(message: m, inputModalities: [.image])
            #expect(r.action == .executeCapability, "\(m) → \(r.action)")
            #expect(r.capability == .imageEdit, "\(m) → \(String(describing: r.capability))")
        }
    }

    @Test func backgroundRemovalStaysSegmentation() {
        #expect(route("remove the background").capability == .imageSegment)
        #expect(route("make the background transparent").capability != .imageEdit)
    }

    @Test func vagueImproveStaysClarify() {
        let r = route("make this better")
        #expect(r.action == .clarify)
        #expect(r.clarifyKind == .ambiguous)
    }

    @Test func upscaleStaysUpscaleNotEdit() {
        #expect(route("upscale this 2x").capability == .imageUpscale)
    }
}
