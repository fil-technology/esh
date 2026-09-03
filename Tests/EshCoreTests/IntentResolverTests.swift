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
    func upscaleWithMissingModelIsInstallRequiredThenReadyOncePresent() throws {
        let r = root(); let resolver = IntentResolver()
        // No model asset yet → install required (Real-ESRGAN), original request preserved.
        let out1 = resolver.resolve(message: "Upscale this 2×", attachments: [image()], registry: registry(), installs: [], root: r)
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

        let out2 = resolver.resolve(message: "Upscale this 2×", attachments: [image()], registry: registry(), installs: [], root: r)
        #expect(out2.isReady)
    }

    @Test
    func understandNeedsAVisionModelUntilOneIsInstalled() {
        let r = root(); let resolver = IntentResolver()
        let out = resolver.resolve(message: "what is in this image?", attachments: [image()], registry: registry(), installs: [], root: r)
        guard case let .installRequired(_, _, req) = out else { Issue.record("expected installRequired, got \(out)"); return }
        #expect(req.capability == .imageUnderstand)
    }

    @Test
    func chatAndClarifyAndUnsupportedPassThrough() {
        let r = root(); let resolver = IntentResolver()
        if case .chat = resolver.resolve(message: "Explain recursion", attachments: [], registry: registry(), installs: [], root: r) {} else { Issue.record("expected chat") }
        if case .clarify = resolver.resolve(message: "improve this", attachments: [image()], registry: registry(), installs: [], root: r) {} else { Issue.record("expected clarify") }
        if case .unsupported = resolver.resolve(message: "deploy this", attachments: [], registry: registry(), installs: [], root: r) {} else { Issue.record("expected unsupported") }
    }

    @Test
    func capabilityWithNoRegisteredProviderIsUnsupported() {
        let r = root(); let resolver = IntentResolver()
        // audio.diarize is NOT in this test registry → unsupported (router proposes, esh validates).
        let out = resolver.resolve(message: "who spoke when?", attachments: [EshAttachment(kind: .audio, mimeType: "audio/wav", base64: "AA==")], registry: registry(), installs: [], root: r)
        if case .unsupported = out {} else { Issue.record("expected unsupported, got \(out)") }
    }

    @Test
    func installAndResumeRunsTheOriginalRequestWithoutRepeating() async throws {
        let r = root(); let resolver = IntentResolver()
        let store = PendingInvocationStore()
        let svc = InstallAndResumeService(store: store, resolver: resolver)
        let reg = registry()

        let out = resolver.resolve(message: "Upscale this 2×", attachments: [image()], registry: reg, installs: [], root: r)
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
