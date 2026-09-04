import Foundation

// esh 2.1 UCMR — Managed Project Runtime, Phase 3: generic browser-native (Tier B) project runtime.
//
// A Tier-B project is an interactive browser-module app (ES modules + approved vendored libraries like
// Three.js) — NO Node, NO build, NO dev-server. It extends the static project.generate pipeline with:
//   • the esh-OWNED SECURITY ENVELOPE — esh writes index.html, the import map, and the module bootstrap;
//     the model writes ONLY the application/scene logic (app.js + optional style.css). Generated code never
//     controls the import map, CSP, or which files are trusted.
//   • dependency resolution against the curated offline registry (WebLibRegistry) — the model imports a bare
//     specifier ("three"); esh resolves it to a pinned, integrity-verified, vendored file copied INTO the
//     bundle and mapped by an import map. Unknown/URL/relative-escape imports are rejected, never installed.
//   • network denied by default (permissions.network = .none → CSP connect-src 'none').
// The result is a self-contained `.webProject` ProjectArtifact (v2 manifest) served same-origin and previewed
// in the opaque-origin sandboxed iframe.

/// Pure, testable helpers for composing a Tier-B project (no model, no I/O).
public enum BrowserModuleComposer {
    /// An ES-module import found in generated source.
    public struct ImportRef: Sendable, Equatable {
        public enum Kind: String, Sendable { case bare, relative, url }
        public let specifier: String
        public let kind: Kind
    }

    /// Classify a module specifier: URL (http/https/protocol-relative), relative/absolute path, or bare.
    public static func classify(_ spec: String) -> ImportRef.Kind {
        let s = spec.trimmingCharacters(in: .whitespaces)
        let low = s.lowercased()
        if low.hasPrefix("http://") || low.hasPrefix("https://") || low.hasPrefix("//") || low.hasPrefix("data:") { return .url }
        if s.hasPrefix("./") || s.hasPrefix("../") || s.hasPrefix("/") { return .relative }
        return .bare
    }

    /// Extract every module specifier imported by `js` — static `import … from "x"`, side-effect `import "x"`,
    /// and dynamic `import("x")` (so a dynamic import can't smuggle a remote URL past the check).
    public static func imports(inJS js: String) -> [ImportRef] {
        var refs: [ImportRef] = []
        let patterns = [
            #"import\s+[^;'"]*?\s+from\s*["']([^"']+)["']"#,   // import X / {a} / * as N from "x"
            #"import\s*["']([^"']+)["']"#,                       // import "x"
            #"import\s*\(\s*["']([^"']+)["']\s*\)"#             // import("x")
        ]
        var seen = Set<String>()
        for p in patterns {
            for spec in ProjectConsistency.matches(p, in: js) where seen.insert(spec).inserted {
                refs.append(ImportRef(specifier: spec, kind: classify(spec)))
            }
        }
        return refs
    }

    /// The esh-owned entrypoint HTML: import map + a bootstrap that exposes each resolved library's global +
    /// a mount point + the app module. The model never writes this, so it cannot inject a remote import,
    /// change the import map, or alter the security setup. `globals` maps import specifier → browser global
    /// (e.g. "three" → "THREE") so natural global-style code works; the import specifier also stays available
    /// for correct ESM imports via the import map.
    public static func scaffoldIndexHTML(title: String, importMap: [String: String],
                                         globals: [(specifier: String, global: String)],
                                         hasStyle: Bool, appEntry: String) -> String {
        let mapJSON = (try? String(data: JSONSerialization.data(withJSONObject: ["imports": importMap],
                                                                options: [.sortedKeys]), encoding: .utf8)) ?? #"{"imports":{}}"#
        let styleLink = hasStyle ? "\n  <link rel=\"stylesheet\" href=\"style.css\">" : ""
        let safeTitle = title.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        // esh-owned bootstrap: import each resolved lib and expose its conventional global BEFORE app.js runs
        // (module scripts execute in document order), so `THREE.*` code works even without an explicit import.
        var bootstrap = ""
        if !globals.isEmpty {
            var lines: [String] = []
            for (i, g) in globals.enumerated() {
                lines.append("import * as __eshlib\(i) from \"\(g.specifier)\";")
                lines.append("globalThis.\(g.global) = __eshlib\(i).default ?? __eshlib\(i);")
            }
            bootstrap = "\n  <script type=\"module\">\n\(lines.map { "  " + $0 }.joined(separator: "\n"))\n  </script>"
        }
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>\(safeTitle)</title>\(styleLink)
          <script type="importmap">
        \(mapJSON)
          </script>\(bootstrap)
        </head>
        <body>
          <div id="app"></div>
          <script type="module" src="\(appEntry)"></script>
        </body>
        </html>
        """
    }

    /// Three.js-specialized scaffold: esh OWNS a correctly-sized renderer + scene + camera + lights + the
    /// render loop, so the model writes only scene content (add objects to the global `scene`) and an optional
    /// per-frame `window.eshTick(dt)`. This makes output small + reliable (fixes the common 0×0-canvas / no
    /// render-loop bugs) and keeps esh owning the runtime bootstrap. `three` must be in `importMap`.
    public static func scaffoldThreeJSIndexHTML(title: String, importMap: [String: String],
                                                hasStyle: Bool, appEntry: String) -> String {
        let mapJSON = (try? String(data: JSONSerialization.data(withJSONObject: ["imports": importMap],
                                                                options: [.sortedKeys]), encoding: .utf8)) ?? #"{"imports":{}}"#
        let styleLink = hasStyle ? "\n  <link rel=\"stylesheet\" href=\"style.css\">" : ""
        let safeTitle = title.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let bootstrap = """
        import * as THREE from "three";
          globalThis.THREE = THREE;
          const app = document.getElementById('app');
          const renderer = new THREE.WebGLRenderer({ antialias: true });
          renderer.setPixelRatio(window.devicePixelRatio || 1);
          app.appendChild(renderer.domElement);
          const scene = new THREE.Scene();
          const camera = new THREE.PerspectiveCamera(60, 1, 0.1, 2000);
          camera.position.set(0, 0, 5);
          scene.add(new THREE.AmbientLight(0xffffff, 0.6));
          const _dir = new THREE.DirectionalLight(0xffffff, 0.9); _dir.position.set(5, 3, 5); scene.add(_dir);
          globalThis.scene = scene; globalThis.camera = camera; globalThis.renderer = renderer;
          function _resize() {
            const w = app.clientWidth || window.innerWidth, h = app.clientHeight || window.innerHeight;
            renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix();
          }
          _resize(); window.addEventListener('resize', _resize);
          let _last = performance.now();
          function _loop(now) {
            const dt = Math.min(0.1, (now - _last) / 1000); _last = now;
            try { if (typeof globalThis.eshTick === 'function') globalThis.eshTick(dt); } catch (e) { console.error(e); }
            renderer.render(scene, camera); requestAnimationFrame(_loop);
          }
          requestAnimationFrame(_loop);
        """
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>\(safeTitle)</title>
          <style>html,body{margin:0;height:100%;overflow:hidden;background:#000;color:#eee;font-family:system-ui,sans-serif}#app{position:fixed;inset:0}#app canvas{display:block}.ui{position:fixed;top:10px;left:10px;z-index:10;display:flex;gap:8px}.ui button{padding:6px 10px;border:0;border-radius:6px;background:#2563eb;color:#fff;cursor:pointer;font:inherit}</style>\(styleLink)
          <script type="importmap">
        \(mapJSON)
          </script>
        </head>
        <body>
          <div id="app"></div>
          <script type="module">
        \(bootstrap)
          </script>
          <script type="module" src="\(appEntry)"></script>
        </body>
        </html>
        """
    }

    /// The project type requested via ExecutionOptions["projectType"], if it names a browser-module tier.
    public static func requestedTierBType(_ req: ExecutionRequest) -> ProjectType? {
        guard case .string(let raw)? = req.options.values["projectType"] else { return nil }
        switch raw.lowercased() {
        case "threejs", "three": return .threejs
        case "browsermodule", "browser-module", "browser-native", "browsernative": return .browserModule
        default: return nil
        }
    }
}
