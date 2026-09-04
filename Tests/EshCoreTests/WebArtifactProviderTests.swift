import Foundation
import Testing
@testable import EshCore

@Suite
struct WebArtifactProviderTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-web-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    private func mockInfer(_ html: String) -> WebArtifactProvider.InferFn {
        { _ in ExternalInferenceResponse(modelID: "m", backend: .mlx, integration: .init(mode: "direct"),
                                         outputText: html, metrics: .init(contextTokens: 1)) }
    }

    @Test func producesWebProjectArtifact() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = "<!DOCTYPE html><html><head><style>body{background:#111;color:#eee}</style></head><body><h1>Hi</h1><script>console.log(1)</script></body></html>"
        let provider = WebArtifactProvider(infer: mockInfer(doc))
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(ExecutionRequest(
            capability: .webArtifactGenerate, inputs: [.text("a dark hello page")], output: .webArtifact))
        let art = try #require(result.outputs.first)
        #expect(art.kind == .webProject)
        #expect(art.entrypoint == "index.html")
        #expect(art.metadata["selfContained"] == .bool(true))
        #expect(art.generatedBy.capability == .webArtifactGenerate)
        let bytes = try #require(try ctx.artifactStore.data(id: art.id, file: "index.html"))
        #expect(String(decoding: bytes, as: UTF8.self).contains("<h1>Hi</h1>"))
    }

    @Test func revisesPriorArtifactWithLineage() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        // v1
        let r1 = try await CapabilityExecutionService(registry: CapabilityRegistry(providers: [
            WebArtifactProvider(infer: mockInfer("<!DOCTYPE html><html><body><h1>v1 page</h1></body></html>"))]), context: ctx)
            .executeCollecting(ExecutionRequest(capability: .webArtifactGenerate, inputs: [.text("a v1 page")], output: .webArtifact))
        let a1 = try #require(r1.outputs.first)
        // Revise: the infer proves it received the prior HTML (returns v2 only then), and lineage is recorded.
        let reviser = WebArtifactProvider(infer: { req in
            let sawPrior = (req.messages.last?.text ?? "").contains("<h1>v1 page</h1>")
            let out = sawPrior ? "<!DOCTYPE html><html><body><h1>v2 page</h1></body></html>"
                               : "<!DOCTYPE html><html><body>no prior seen</body></html>"
            return ExternalInferenceResponse(modelID: "m", backend: .mlx, integration: .init(mode: "direct"),
                                             outputText: out, metrics: .init(contextTokens: 1))
        })
        let r2 = try await CapabilityExecutionService(registry: CapabilityRegistry(providers: [reviser]), context: ctx)
            .executeCollecting(ExecutionRequest(capability: .webArtifactGenerate, inputs: [.text("rename heading to v2")],
                output: .webArtifact, options: ExecutionOptions(["sourceArtifactID": .string(a1.id.uuidString)])))
        let a2 = try #require(r2.outputs.first)
        #expect(a2.generatedBy.sourceArtifactID == a1.id)     // lineage
        #expect(a2.metadata["revised"] == .bool(true))
        let html2 = try #require(try ctx.artifactStore.data(id: a2.id, file: "index.html"))
        #expect(String(decoding: html2, as: UTF8.self).contains("<h1>v2 page</h1>"))   // proves prior HTML was loaded
    }

    @Test func extractsHTMLFromMarkdownFencesAndProse() {
        let raw = "Sure! Here is your page:\n```html\n<!DOCTYPE html><html><body>ok</body></html>\n```\nHope it helps!"
        let html = WebArtifactProvider.extractHTML(raw)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.hasSuffix("</html>"))
        #expect(!html.contains("Hope it helps"))
    }

    @Test func validatorFlagsExternalResourcesButStaysValid() {
        let ext = "<!DOCTYPE html><html><head><script src=\"https://cdn.example.com/x.js\"></script></head><body>hi there world</body></html>"
        let v = WebArtifactValidator.validate(ext)
        #expect(v.isValid)                                   // still previewable (sandboxed)
        #expect(v.findings.contains { $0.contains("external resource") })   // but not self-contained
    }

    @Test func validatorRejectsNonHTML() {
        #expect(!WebArtifactValidator.validate("I cannot do that.").isValid)
        #expect(!WebArtifactValidator.validate("").isValid)
    }

    // MARK: - Tier-0 routing

    private let router = DeterministicIntentRouter()
    private func cap(_ m: String) -> CapabilityID? { router.route(message: m, inputModalities: []).capability }

    @Test func webPageRequestsRouteToWebArtifact() {
        for m in ["build a landing page for a coffee shop", "make a web page with a countdown timer",
                  "create a website for my portfolio", "generate an html page with a contact form"] {
            #expect(cap(m) == .webArtifactGenerate, "\(m) → \(String(describing: cap(m)))")
        }
    }

    @Test func webRoutingDoesNotStealSvgOrImageOrChat() {
        #expect(cap("create an SVG logo of a fox") == .vectorGenerate)
        #expect(cap("generate a watercolor fox") == .imageGenerate)
        #expect(router.route(message: "explain how HTML works", inputModalities: []).action == .chat)
        #expect(router.route(message: "write a haiku about the web", inputModalities: []).action == .chat)
    }
}
