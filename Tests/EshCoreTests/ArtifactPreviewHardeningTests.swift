import Foundation
import Testing
@testable import EshCore

@Suite
struct ArtifactPreviewHardeningTests {
    // A minimal provider that emits a preview URL, to prove `.previewReady` is no longer dropped.
    private struct PreviewProvider: CapabilityProvider {
        let descriptor = CapabilityProviderDescriptor(
            id: "preview-test", capabilities: [.projectGenerate], acceptedInputs: [.text],
            producedOutputs: [.text], backend: .native, previewMode: .managed)
        func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
            AsyncThrowingStream { cont in
                cont.yield(.previewReady(url: "http://127.0.0.1:11466/v1/artifacts/abc/index.html"))
                cont.yield(.done(finishReason: "stop"))
                cont.finish()
            }
        }
        func unload() async {}
    }

    @Test func previewReadySurfacesInResult() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-prev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                   artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts")))
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [PreviewProvider()]), context: ctx)
        let r = try await svc.executeCollecting(ExecutionRequest(capability: .projectGenerate, inputs: [.text("x")], output: .project))
        #expect(r.previewURL == "http://127.0.0.1:11466/v1/artifacts/abc/index.html")
    }

    @Test func defaultArtifactCSPLocksDownNetworkAndFraming() {
        let csp = OpenAICompatibleService.defaultArtifactCSP
        #expect(csp.contains("connect-src 'none'"))     // no network egress from generated code
        #expect(csp.contains("object-src 'none'"))       // no plugins
        #expect(csp.contains("base-uri 'none'"))         // no <base> hijack
        #expect(csp.contains("frame-ancestors 'self'"))  // only esh may frame it
        // Must NOT constrain script/style/img — the opaque-origin sandbox + inline webArtifacts rely on that.
        #expect(!csp.contains("script-src"))
        #expect(!csp.contains("style-src"))
    }

    @Test func executionResultPreviewURLRoundTrips() throws {
        let r = ExecutionResult(capability: .projectGenerate, previewURL: "http://x/y")
        let data = try JSONCoding.encoder.encode(r)
        let back = try JSONCoding.decoder.decode(ExecutionResult.self, from: data)
        #expect(back.previewURL == "http://x/y")
        // A payload without previewURL still decodes (backward compatible).
        let legacy = try JSONCoding.decoder.decode(ExecutionResult.self, from: Data(#"{"capability":"project.generate"}"#.utf8))
        #expect(legacy.previewURL == nil)
    }
}
