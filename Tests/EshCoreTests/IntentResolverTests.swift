import Foundation
import Testing
@testable import EshCore

@Suite
struct IntentResolverTests {
    // A registry with real provider descriptors so capability registration is validated honestly.
    private func registry() -> CapabilityRegistry {
        CapabilityRegistry(providers: [
            ImageUpscaleProvider(upscale: { _, _, _, _, _ in (1, 1) }),
            VisionUnderstandProvider(understand: { _, _, _, _ in "" }),
        ])
    }
    private func root() -> PersistenceRoot {
        PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-router-\(UUID().uuidString)"))
    }
    private func image() -> EshAttachment { EshAttachment(kind: .image, mimeType: "image/png", base64: Data([1]).base64EncodedString()) }

    @Test
    func upscaleWithMissingModelIsInstallRequiredThenReadyOncePresent() async throws {
        let r = root(); let resolver = IntentResolver()
        // No model asset yet → install required (Real-ESRGAN), original request preserved.
        let out1 = await resolver.resolve(message: "Upscale this 2×", attachments: [image()], registry: registry(), installs: [], root: r)
        guard case let .installRequired(request, intent, requirement) = out1 else {
            Issue.record("expected installRequired, got \(out1)"); return
        }
        #expect(requirement.componentName == "Real-ESRGAN")
        #expect(request.capability == .imageUpscale)
        #expect(request.options.values["scale"] == .int(2))
        #expect(intent.capability == .imageUpscale)

        // Simulate install: create the model asset under the assets caches root.
        let asset = r.cachesURL.appendingPathComponent("upscale-models/real_esrgan_x4.onnx")
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: asset)
        defer { try? FileManager.default.removeItem(at: r.stateRootURL); try? FileManager.default.removeItem(at: r.assetsRootURL) }

        let out2 = await resolver.resolve(message: "Upscale this 2×", attachments: [image()], registry: registry(), installs: [], root: r)
        #expect(out2.isReady)
    }

    @Test
    func understandNeedsAVisionModelUntilOneIsInstalled() async {
        let r = root(); let resolver = IntentResolver()
        let out = await resolver.resolve(message: "what is in this image?", attachments: [image()], registry: registry(), installs: [], root: r)
        guard case let .installRequired(_, _, req) = out else { Issue.record("expected installRequired, got \(out)"); return }
        #expect(req.capability == .imageUnderstand)
    }

    @Test
    func chatAndClarifyAndUnsupportedPassThrough() async {
        let r = root(); let resolver = IntentResolver()
        if case .chat = await resolver.resolve(message: "Explain recursion", attachments: [], registry: registry(), installs: [], root: r) {} else { Issue.record("expected chat") }
        if case .clarify = await resolver.resolve(message: "improve this", attachments: [image()], registry: registry(), installs: [], root: r) {} else { Issue.record("expected clarify") }
        if case .unsupported = await resolver.resolve(message: "deploy this", attachments: [], registry: registry(), installs: [], root: r) {} else { Issue.record("expected unsupported") }
    }

    @Test
    func capabilityWithNoRegisteredProviderIsUnsupported() async {
        let r = root(); let resolver = IntentResolver()
        // audio.diarize is NOT in this test registry → unsupported (router proposes, esh validates).
        let out = await resolver.resolve(message: "who spoke when?", attachments: [EshAttachment(kind: .audio, mimeType: "audio/wav", base64: "AA==")], registry: registry(), installs: [], root: r)
        if case .unsupported = out {} else { Issue.record("expected unsupported, got \(out)") }
    }

    // A mock Tier-1 router that always proposes a fixed capability (or an invalid one). It reports every
    // request as "specific" so the Safety Validator's specific-vs-vague check passes (unless verifyVague).
    struct MockSemantic: SemanticIntentRouter {
        let name = "mock"; let cap: CapabilityID?; var verifyVague = false
        func propose(message: String, inputModalities: [ModelModality], schema: [CapabilitySchemaEntry]) async -> CapabilityIntent? {
            guard let cap else { return CapabilityIntent(action: .abstain, provenance: .init(tier: "tier1-semantic", router: "mock")) }
            return CapabilityIntent(action: .executeCapability, capability: cap, inputRefs: ["attachment_0"],
                                    provenance: .init(tier: "tier1-semantic", router: "mock"))
        }
        func verifySpecific(message: String, capability: CapabilityID, inputModalities: [ModelModality]) async -> Bool? { !verifyVague }
    }

    @Test
    func tier1ResolvesUnresolvedWhenItNamesARegisteredCapability() async {
        let r = root()
        // A non-Latin request is Tier-0 UNRESOLVED (not ambiguous) → escalation is allowed. Tier-1 proposes
        // image.upscale (registered) and the Safety Validator says "specific" → the resolver adopts it (here
        // installRequired since the upscale asset isn't present — the point is it became a validated capability).
        let resolver = IntentResolver(semantic: MockSemantic(cap: .imageUpscale))
        let out = await resolver.resolve(message: "Что здесь написано?", attachments: [image()], registry: registry(), installs: [], root: r)
        switch out {
        case let .installRequired(request, _, _): #expect(request.capability == .imageUpscale)
        case let .ready(request, _): #expect(request.capability == .imageUpscale)
        default: Issue.record("expected image.upscale (Tier-1 escalation on unresolved), got \(out)")
        }
    }

    @Test
    func ambiguousClarifyIsNeverEscalated() async {
        let r = root()
        // "improve this" is Tier-0 AMBIGUOUS → must stay a clarify even with a Tier-1 router present (no
        // escalation authority for ambiguous — this is what keeps false-execution near zero).
        let resolver = IntentResolver(semantic: MockSemantic(cap: .imageUpscale))
        let out = await resolver.resolve(message: "improve this", attachments: [image()], registry: registry(), installs: [], root: r)
        if case .clarify = out {} else { Issue.record("expected clarify (ambiguous never escalates), got \(out)") }
    }

    @Test
    func safetyValidatorVetoesVagueProposal() async {
        let r = root()
        // Unresolved case, router proposes a registered capability, but the Safety Validator judges the
        // request VAGUE → the proposal is withheld and Tier-0's clarify stands.
        let resolver = IntentResolver(semantic: MockSemantic(cap: .imageUpscale, verifyVague: true))
        let out = await resolver.resolve(message: "Что здесь написано?", attachments: [image()], registry: registry(), installs: [], root: r)
        if case .clarify = out {} else { Issue.record("expected clarify (Safety Validator veto), got \(out)") }
    }

    @Test
    func tier1ProposalForAnUnregisteredCapabilityIsRejected() async {
        let r = root()
        // Unresolved case; Tier-1 proposes audio.diarize, which has NO provider in this registry → keep clarify.
        let resolver = IntentResolver(semantic: MockSemantic(cap: .audioDiarize))
        let out = await resolver.resolve(message: "Что здесь написано?", attachments: [image()], registry: registry(), installs: [], root: r)
        if case .clarify = out {} else { Issue.record("expected clarify (invalid proposal rejected), got \(out)") }
    }

    @Test
    func installAndResumeRunsTheOriginalRequestWithoutRepeating() async throws {
        let r = root(); let resolver = IntentResolver()
        let store = PendingInvocationStore()
        let svc = InstallAndResumeService(store: store, resolver: resolver)
        let reg = registry()

        let out = await resolver.resolve(message: "Upscale this 2×", attachments: [image()], registry: reg, installs: [], root: r)
        guard case let .installRequired(_, intent, requirement) = out else { Issue.record("expected installRequired"); return }
        let pending = await svc.record(message: "Upscale this 2×", attachments: [image()], intent: intent,
                                       requirement: requirement, conversationID: "c1", nowISO8601: "2026-09-03T00:00:00Z")

        // "Install" the component.
        let asset = r.cachesURL.appendingPathComponent("upscale-models/real_esrgan_x4.onnx")
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: asset)
        defer { try? FileManager.default.removeItem(at: r.stateRootURL); try? FileManager.default.removeItem(at: r.assetsRootURL) }

        // Resume: re-validate + execute the ORIGINAL request. The user never re-typed it.
        let resumed = await svc.resume(pending.id, registry: reg, installs: [], root: r, execute: { req in
            #expect(req.capability == .imageUpscale)
            #expect(req.options.values["scale"] == .int(2))
            return ExecutionResult(capability: .imageUpscale, text: "ok")
        })
        guard case let .executed(result) = resumed else { Issue.record("expected executed, got \(resumed)"); return }
        #expect(result.capability == .imageUpscale)
        // Pending is cleared after a successful resume.
        #expect(await store.get(pending.id) == nil)
    }
}
