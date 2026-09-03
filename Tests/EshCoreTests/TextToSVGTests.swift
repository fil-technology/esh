import Foundation
import Testing
@testable import EshCore

@Suite
struct TextToSVGTests {
    // MARK: Renderer

    @Test
    func rendersWhitelistedElementsDeterministically() {
        var circle = SVGSceneElement(type: "circle")
        circle.cx = 32; circle.cy = 32; circle.r = 20; circle.fill = "#ffcc00"; circle.stroke = "black"; circle.strokeWidth = 2
        let scene = SVGScene(width: 64, height: 64, background: "#fff", elements: [circle])
        let svg = SVGSceneRenderer.render(scene)
        #expect(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\""))
        #expect(svg.contains("<circle cx=\"32\" cy=\"32\" r=\"20\" fill=\"#ffcc00\" stroke=\"black\" stroke-width=\"2\"/>"))
        #expect(svg.contains("<rect x=\"0\" y=\"0\" width=\"64\" height=\"64\" fill=\"#fff\"/>"))
        #expect(SVGValidator.validate(svg, expectedWidth: 64, expectedHeight: 64).isValid)
    }

    @Test
    func dropsUnsafeAttributesAndElements() {
        var evil = SVGSceneElement(type: "rect")
        evil.x = 0; evil.y = 0; evil.width = 10; evil.height = 10
        evil.fill = "url(http://evil/x)"          // rejected color → dropped
        evil.transform = "translate(5,5)"          // safe transform kept
        var bogus = SVGSceneElement(type: "script") // unknown type → dropped
        bogus.text = "alert(1)"
        var textEl = SVGSceneElement(type: "text")
        textEl.x = 5; textEl.y = 5; textEl.text = "<img src=x onerror=alert(1)>"  // escaped
        let scene = SVGScene(width: 20, height: 20, elements: [evil, bogus, textEl])
        let svg = SVGSceneRenderer.render(scene)
        #expect(!svg.contains("url("))
        #expect(!svg.lowercased().contains("<script"))
        #expect(svg.contains("transform=\"translate(5,5)\""))
        #expect(svg.contains("&lt;img"))          // text escaped, not raw
        #expect(!svg.contains("<img src=x"))
        #expect(SVGValidator.validate(svg, expectedWidth: 20, expectedHeight: 20).isValid)
    }

    @Test
    func sanitizersRejectDangerousValues() {
        #expect(SVGSceneRenderer.safeColor("#ff0000") == "#ff0000")
        #expect(SVGSceneRenderer.safeColor("red") == "red")
        #expect(SVGSceneRenderer.safeColor("rgb(1,2,3)") == "rgb(1,2,3)")
        #expect(SVGSceneRenderer.safeColor("url(#x)") == nil)
        #expect(SVGSceneRenderer.safeColor("javascript:alert(1)") == nil)
        #expect(SVGSceneRenderer.safePathData("M10 10 L20 20 Z") == "M10 10 L20 20 Z")
        #expect(SVGSceneRenderer.safePathData("M10 </path><script>") == nil)
        #expect(SVGSceneRenderer.safeTransform("rotate(45) translate(1,2)") == "rotate(45) translate(1,2)")
        #expect(SVGSceneRenderer.safeTransform("rotate(45);behavior:url(x)") == nil)
    }

    @Test
    func validatorFlagsDangerousSVG() {
        let bad = "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"
        let v = SVGValidator.validate(bad, expectedWidth: 10, expectedHeight: 10)
        #expect(!v.isValid)
        #expect(v.findings.contains { $0.contains("script") })
    }

    // MARK: Provider (with a mock LLM returning a scene IR)

    @Test
    func providerGeneratesValidSVGArtifactFromModelJSON() async throws {
        let json = """
        Here you go: {"width":100,"height":100,"background":"#eef","elements":[{"type":"circle","cx":50,"cy":50,"r":40,"fill":"#3a7"}]}
        """
        let provider = TextToSVGProvider(infer: { _ in
            ExternalInferenceResponse(modelID: "mock", backend: .gguf,
                                      integration: ExternalInferenceIntegration(mode: "direct"),
                                      outputText: json, metrics: Metrics())
        })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-svg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                   artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts")))
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(
            ExecutionRequest(capability: .vectorGenerate, inputs: [.text("a green circle")], output: .svg))
        #expect(result.outputs.count == 1)
        let art = try #require(result.outputs.first)
        #expect(art.kind == .svg)
        #expect(art.validation.isValid)
        #expect(art.metadata["width"] == .int(100))
        let bytes = try #require(try ctx.artifactStore.data(id: art.id, file: "scene.svg"))
        let svg = String(decoding: bytes, as: UTF8.self)
        #expect(svg.contains("<circle"))
        #expect(svg.contains("#3a7"))
    }

    @Test
    func jsonExtractionHandlesWrappedResponses() {
        #expect(TextToSVGProvider.extractJSONObject("prefix {\"a\":1} suffix") == "{\"a\":1}")
        #expect(TextToSVGProvider.extractJSONObject("no json here") == nil)
    }
}
