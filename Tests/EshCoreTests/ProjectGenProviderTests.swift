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
    /// Returns a different response per call (last one repeats) — models the generate → repair round-trips.
    private actor Seq { var i = 0; let items: [String]; init(_ items: [String]) { self.items = items }
        func next() -> String { let v = items[min(i, items.count - 1)]; i += 1; return v } }
    private func seqMock(_ items: [String]) -> ProjectGenProvider.InferFn {
        let s = Seq(items)
        return { _ in ExternalInferenceResponse(modelID: "m", backend: .mlx, integration: .init(mode: "direct"),
                                                outputText: await s.next(), metrics: .init(contextTokens: 1)) }
    }
    // A cross-file-BROKEN project: script.js targets #back-to-top, but index.html has no such element.
    private let brokenJSON = #"{"files":[{"path":"index.html","content":"<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body><main><h1>Hi</h1></main><script src=\"script.js\"></script></body></html>"},{"path":"style.css","content":"body{margin:0}"},{"path":"script.js","content":"const b=document.getElementById('back-to-top'); b.addEventListener('click',()=>window.scrollTo(0,0));"}]}"#
    // The repaired version: adds the <button id="back-to-top"> the script needs.
    private let fixedJSON = #"{"files":[{"path":"index.html","content":"<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body><main><h1>Hi</h1></main><button id=\"back-to-top\">Top</button><script src=\"script.js\"></script></body></html>"},{"path":"style.css","content":"body{margin:0}"},{"path":"script.js","content":"const b=document.getElementById('back-to-top'); b.addEventListener('click',()=>window.scrollTo(0,0));"}]}"#

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

    // MARK: - Layer 2: cross-file consistency

    @Test func consistencyFlagsMissingJSTarget() {
        let files = [("index.html", "<!DOCTYPE html><html><body><h1>x</h1><script src=\"script.js\"></script></body></html>"),
                     ("script.js", "document.getElementById('back-to-top').style.display='none';")]
        #expect(ProjectConsistency.check(files).contains { $0.kind == .missingJSTarget })
        // Same script, but the element now exists → no missing-target issue.
        let ok = [("index.html", "<!DOCTYPE html><html><body><button id=\"back-to-top\">Top</button><script src=\"script.js\"></script></body></html>"),
                  ("script.js", "document.getElementById('back-to-top').style.display='none';")]
        #expect(!ProjectConsistency.check(ok).contains { $0.kind == .missingJSTarget })
    }

    @Test func consistencyFlagsQuerySelectorTargetAndSkipsClasses() {
        let missing = [("index.html", "<!DOCTYPE html><html><body><div></div><script src=\"s.js\"></script></body></html>"),
                       ("s.js", "document.querySelector('#hero').classList.add('on');")]
        #expect(ProjectConsistency.check(missing).contains { $0.kind == .missingJSTarget })
        // Class selectors are NOT flagged (classList / dynamic classes make them unreliable to verify).
        let classSel = [("index.html", "<!DOCTYPE html><html><body><div></div><script src=\"s.js\"></script></body></html>"),
                        ("s.js", "document.querySelector('.card').remove();")]
        #expect(!ProjectConsistency.check(classSel).contains { $0.kind == .missingJSTarget })
    }

    @Test func consistencyFlagsMissingLinkedFileAndBadPath() {
        let missingCSS = [("index.html", "<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body>x</body></html>")]
        #expect(ProjectConsistency.check(missingCSS).contains { $0.kind == .missingLinkedFile })
        let absPath = [("index.html", "<!DOCTYPE html><html><body><img src=\"/Users/me/pic.png\"></body></html>")]
        #expect(ProjectConsistency.check(absPath).contains { $0.kind == .badLocalPath })
        // A remote/data ref is NOT a local-file problem for this layer.
        let remote = [("index.html", "<!DOCTYPE html><html><body><img src=\"data:image/png;base64,AAAA\"></body></html>")]
        #expect(!ProjectConsistency.check(remote).contains { $0.kind == .missingLinkedFile || $0.kind == .badLocalPath })
    }

    @Test func consistencyFlagsStructureAndDuplicateID() {
        let noBody = [("index.html", "<!DOCTYPE html><html><h1>hi there friends</h1></html>")]
        #expect(ProjectConsistency.check(noBody).contains { $0.kind == .malformedStructure })
        let dup = [("index.html", "<!DOCTYPE html><html><body><div id=\"a\"></div><div id=\"a\"></div></body></html>")]
        #expect(ProjectConsistency.check(dup).contains { $0.kind == .duplicateID })
    }

    @Test func consistencyFlagsWrappedAndOrphanedAssets() {
        // .css / .js wrapped in HTML tags → malformedAsset (would be served with the wrong content type).
        let wrapped = [("index.html", "<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body>x<script src=\"app.js\"></script></body></html>"),
                       ("style.css", "<style>body{margin:0}</style>"),
                       ("app.js", "<script>console.log(1)</script>")]
        let wIssues = ProjectConsistency.check(wrapped)
        #expect(wIssues.filter { $0.kind == .malformedAsset }.count == 2)
        // A script file that the HTML never includes → unreferencedFile (dead code, e.g. a toggle that never runs).
        let orphan = [("index.html", "<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body><button id=\"b\">x</button></body></html>"),
                      ("style.css", "body{margin:0}"),
                      ("script.js", "document.getElementById('b').addEventListener('click',()=>{});")]
        #expect(ProjectConsistency.check(orphan).contains { $0.kind == .unreferencedFile })
    }

    @Test func consistencyPassesForCoherentProject() {
        let files = [("index.html", "<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body><button id=\"go\">go</button><script src=\"app.js\"></script></body></html>"),
                     ("style.css", "body{margin:0}"),
                     ("app.js", "document.getElementById('go').addEventListener('click',()=>{});")]
        #expect(ProjectConsistency.check(files).isEmpty)
    }

    // MARK: - Bounded repair loop

    @Test func repairsCrossFileInconsistency() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        // First reply is cross-file broken; the repair round-trip returns the fixed project.
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [ProjectGenProvider(infer: seqMock([brokenJSON, fixedJSON]))]), context: ctx)
        let r = try await svc.executeCollecting(ExecutionRequest(capability: .projectGenerate, inputs: [.text("a site with a back-to-top button")], output: .project))
        let a = try #require(r.outputs.first)
        #expect(a.validation.isValid)                 // repaired → valid
        #expect(a.metadata["repairAttempts"] == .int(1))
        // The saved index.html now actually contains the element the script targets.
        let html = String(data: try #require(try ctx.artifactStore.data(id: a.id, file: "index.html")), encoding: .utf8) ?? ""
        #expect(html.contains("id=\"back-to-top\""))
    }

    @Test func unrepairableProjectIsSavedButMarkedInvalid() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        // Model keeps returning the same broken project → repair can't reduce issues → honest invalid.
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [ProjectGenProvider(infer: seqMock([brokenJSON]))]), context: ctx)
        let r = try await svc.executeCollecting(ExecutionRequest(capability: .projectGenerate, inputs: [.text("x")], output: .project))
        let a = try #require(r.outputs.first)
        #expect(!a.validation.isValid)                // never silently ships broken
        #expect(a.validation.findings.contains { $0.contains("back-to-top") })
        // Structured stage report is present and marks the failing stage.
        if case .object(let report)? = a.metadata["validation"] {
            #expect(report["crossFileReferences"] == .string("failed"))
            #expect(report["entrypoint"] == .string("passed"))
        } else { Issue.record("no structured validation report in metadata") }
    }

    @Test func complexityEstimateSeparatesSmallFromLarge() {
        let small = ProjectComplexity.estimate("a simple hello page with a heading")
        #expect(!small.isLarge)
        #expect(small.expectedFiles == 3)
        let large = ProjectComplexity.estimate("a multi-page admin dashboard with charts, a data table, a sidebar nav, filters and a search box")
        #expect(large.isLarge)
        #expect(large.expectedFiles > 3)
        #expect(large.expectedOutputTokens > ProjectComplexity.appleSafeOutputTokens)
    }

    @Test func routingMultiFileVsSingle() {
        let r = DeterministicIntentRouter()
        #expect(r.route(message: "create a multi-file website for a bakery", inputModalities: []).capability == .projectGenerate)
        #expect(r.route(message: "build a web project with separate html css and js", inputModalities: []).capability == .projectGenerate)
        #expect(r.route(message: "make a landing page for a bakery", inputModalities: []).capability == .webArtifactGenerate)
    }
}
