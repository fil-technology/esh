import Foundation
import Testing
@testable import EshCore

@Suite
struct ProjectGenProviderTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-proj-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }
    private func mock(_ json: String) -> ProjectGenProvider.InferFn {
        { _ in ExternalInferenceResponse(modelID: "m", backend: .mlx, integration: .init(mode: "direct"),
                                         outputText: json, metrics: .init(contextTokens: 1)) }
    }

    @Test func producesMultiFileWebProject() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"files":[{"path":"index.html","content":"<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body><h1>Hi</h1><script src=\"app.js\"></script></body></html>"},{"path":"style.css","content":"h1{color:teal}"},{"path":"app.js","content":"console.log(1)"}]}"#
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [ProjectGenProvider(infer: mock(json))]), context: ctx)
        let r = try await svc.executeCollecting(ExecutionRequest(capability: .projectGenerate, inputs: [.text("a tiny site")], output: .project))
        let a = try #require(r.outputs.first)
        #expect(a.kind == .webProject)
        #expect(a.entrypoint == "index.html")
        #expect(a.metadata["fileCount"] == .int(3))
        // All three files are retrievable from the store.
        for f in ["index.html", "style.css", "app.js"] {
            #expect((try? ctx.artifactStore.data(id: a.id, file: f)) != nil, "missing \(f)")
        }
    }

    @Test func dropsUnsafePathsAndRequiresIndex() {
        let (safe, v) = ProjectValidator.validate([
            ("index.html", "<!DOCTYPE html><html><body><h1>ok</h1></body></html>"),
            ("../evil.sh", "rm -rf /"), ("/etc/passwd", "root:x:0:0"), ("app.js", "console.log(1)")])
        #expect(v.isValid)                                   // has index.html
        #expect(safe.map { $0.0 }.sorted() == ["app.js", "index.html"])   // traversal/absolute dropped
        #expect(v.findings.contains { $0.contains("unsafe path") })
        // No index.html → invalid.
        #expect(!ProjectValidator.validate([("style.css", "x")]).validation.isValid)
    }

    @Test func rejectsPlaceholderContent() {
        // A model that emits "..." / "…" / empty files instead of real code must NOT pass validation.
        #expect(ProjectValidator.isPlaceholder("..."))
        #expect(ProjectValidator.isPlaceholder("…"))
        #expect(ProjectValidator.isPlaceholder("   \n"))
        #expect(ProjectValidator.isPlaceholder("// ..."))
        #expect(!ProjectValidator.isPlaceholder("<!DOCTYPE html><html><body><h1>Hi</h1></body></html>"))
        let (_, v) = ProjectValidator.validate([("index.html", "..."), ("style.css", "…"), ("script.js", "")])
        #expect(!v.isValid)   // every file was a placeholder → no usable index.html
    }

    @Test func flagsExternalResources() {
        let (_, v) = ProjectValidator.validate([("index.html", "<script src=\"https://cdn.x/a.js\"></script>")])
        #expect(v.findings.contains { $0.contains("external resource") })
    }

    @Test func routingMultiFileVsSingle() {
        let r = DeterministicIntentRouter()
        #expect(r.route(message: "create a multi-file website for a bakery", inputModalities: []).capability == .projectGenerate)
        #expect(r.route(message: "build a web project with separate html css and js", inputModalities: []).capability == .projectGenerate)
        #expect(r.route(message: "make a landing page for a bakery", inputModalities: []).capability == .webArtifactGenerate)
    }
}
