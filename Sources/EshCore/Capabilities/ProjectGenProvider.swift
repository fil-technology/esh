import Foundation

// esh 2.1 UCMR — project.generate: text → a small MULTI-FILE static web project (index.html + style.css +
// script.js …) as a typed `.webProject` ProjectArtifact, previewed in the SAME isolated sandbox (the entry
// loads siblings by relative path from the artifact store). Pure LLM codegen — no npm, no build, no
// dev-server (running untrusted generated Node code + a managed runtime is a separate, heavier tier, NOT
// this). Files are validated in TWO layers: (1) path-safety + content-quality + entrypoint; (2) cross-file
// consistency (JS→HTML targets, HTML/CSS→local assets, structure). A bounded repair pass fixes small
// consistency defects before save so the project is not just valid FILES but a coherent PROJECT.

/// One generated project file (from the model's JSON manifest).
struct ProjectFile: Codable, Sendable { let path: String; let content: String }
struct ProjectManifest: Codable, Sendable { let files: [ProjectFile] }

public enum ProjectValidator {
    /// True when a file's content is a placeholder/ellipsis rather than real code — some models emit "…" or
    /// "// ..." instead of writing the file. We reject these so the provider retries / escalates.
    static func isPlaceholder(_ content: String) -> Bool {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // Only dots / ellipsis / comment-ellipsis, or too short to be a real file.
        let stripped = t.replacingOccurrences(of: "…", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "./ \t\r\n<!->/*"))
        return stripped.isEmpty
    }

    /// Layer 1 — returns (safeFiles, validation). Drops unsafe paths; flags external resources. index.html
    /// required and must be real HTML (not a placeholder) for the project to be valid.
    public static func validate(_ files: [(path: String, content: String)]) -> (files: [(path: String, content: String)], validation: ArtifactValidation) {
        var findings: [String] = []
        var safe: [(String, String)] = []
        for f in files {
            let p = f.path.trimmingCharacters(in: .whitespaces)
            // Reject traversal / absolute / empty paths — everything stays inside the artifact bundle.
            if p.isEmpty || p.hasPrefix("/") || p.contains("..") || p.hasPrefix("~") {
                findings.append("dropped unsafe path: \(f.path)"); continue
            }
            if isPlaceholder(f.content) {
                findings.append("\(p): placeholder/empty content — dropped"); continue
            }
            if f.content.lowercased().range(of: #"(src|href)\s*=\s*["']https?:"#, options: .regularExpression) != nil {
                findings.append("\(p): references an external resource — not fully self-contained")
            }
            safe.append((p, f.content))
        }
        let index = safe.first { $0.0.lowercased() == "index.html" }
        if index == nil { findings.append("no index.html entrypoint with real content") }
        // The entrypoint must look like an actual HTML document, not a fragment/placeholder.
        var indexLooksReal = false
        if let index {
            let lower = index.1.lowercased()
            indexLooksReal = index.1.count >= 30 && lower.contains("<") && lower.contains(">")
            if !indexLooksReal { findings.append("index.html is not a usable HTML document") }
        }
        let isValid = index != nil && indexLooksReal && !safe.isEmpty
        return (safe, ArtifactValidation(isValid: isValid, findings: findings))
    }
}

/// Layer 2 — deterministic, conservative CROSS-FILE consistency checks. A project can be valid JSON, valid
/// files, valid paths and valid MIME types while still being broken (e.g. script.js references `#back-to-top`
/// that index.html never defines). These checks catch the common, high-precision cases; they deliberately do
/// NOT attempt full static analysis (no dynamic `classList`/`createElement` reasoning, no CSS cascade).
public enum ProjectConsistency {
    public struct Issue: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case missingJSTarget, missingLinkedFile, badLocalPath, malformedStructure, duplicateID,
                 unresolvedTemplate, malformedAsset, unreferencedFile
        }
        public let kind: Kind
        public let detail: String
        public init(kind: Kind, detail: String) { self.kind = kind; self.detail = detail }
    }

    /// All capture-group-`group` substrings for `pattern` in `text` (case-insensitive, dot spans newlines).
    static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let r = $0.range(at: group)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    public static func check(_ files: [(path: String, content: String)]) -> [Issue] {
        var issues: [Issue] = []
        let byName = Dictionary(files.map { ($0.path.lowercased(), $0.content) }, uniquingKeysWith: { a, _ in a })
        let htmlFiles = files.filter { $0.path.lowercased().hasSuffix(".html") || $0.path.lowercased().hasSuffix(".htm") }
        let jsFiles = files.filter { $0.path.lowercased().hasSuffix(".js") || $0.path.lowercased().hasSuffix(".mjs") }
        let cssFiles = files.filter { $0.path.lowercased().hasSuffix(".css") }
        let htmlBlob = htmlFiles.map { $0.content }.joined(separator: "\n")

        // Element ids declared anywhere in the HTML (used to verify JS references resolve).
        let ids = Set(matches(#"\bid\s*=\s*["']([^"']+)["']"#, in: htmlBlob).map { $0.trimmingCharacters(in: .whitespaces) })

        // --- JS → HTML references (inline <script> bodies + .js files). Only the HIGH-PRECISION id forms:
        //     getElementById('x') and querySelector('#x'). Class / dynamic selectors are skipped on purpose
        //     (classList.add / createElement make them unreliable to verify statically). ---
        let inlineScripts = matches(#"<script\b[^>]*>(.*?)</script>"#, in: htmlBlob)
        let jsBlob = (jsFiles.map { $0.content } + inlineScripts).joined(separator: "\n")
        func firstSelectorToken(_ str: Substring) -> String {
            var out = ""
            for ch in str { if " >+~[:,.#".contains(ch) { break }; out.append(ch) }
            return out
        }
        for idRef in matches(#"getElementById\(\s*["']([^"']+)["']\s*\)"#, in: jsBlob) where !ids.contains(idRef) {
            issues.append(.init(kind: .missingJSTarget,
                                detail: "script references element id \"#\(idRef)\" but no element in the HTML has id=\"\(idRef)\""))
        }
        for sel in matches(#"querySelector(?:All)?\(\s*["']([^"']+)["']\s*\)"#, in: jsBlob) {
            let s = sel.trimmingCharacters(in: .whitespaces)
            guard s.first == "#" else { continue }   // only #id selectors are precise enough to verify
            let name = firstSelectorToken(s.dropFirst())
            if !name.isEmpty, !ids.contains(name) {
                issues.append(.init(kind: .missingJSTarget,
                                    detail: "script querySelector(\"#\(name)\") has no matching element id=\"\(name)\" in the HTML"))
            }
        }

        // --- HTML/CSS → local asset files (must exist, must be a relative in-bundle path) ---
        func checkLocalRef(_ raw: String, _ desc: String) {
            var r = raw.trimmingCharacters(in: .whitespaces)
            if r.isEmpty { return }
            let low = r.lowercased()
            // Skip anything that isn't a local file reference (remote, data/blob, anchors, protocols).
            for p in ["http://", "https://", "//", "data:", "blob:", "mailto:", "tel:", "#", "javascript:"] where low.hasPrefix(p) { return }
            if low.hasPrefix("file:") || r.hasPrefix("/") || r.hasPrefix("~")
                || r.range(of: #"^[a-zA-Z]:[\\/]"#, options: .regularExpression) != nil {
                issues.append(.init(kind: .badLocalPath,
                                    detail: "\(desc) uses an absolute/dev-machine path \"\(raw)\" — must be a relative path inside the project")); return
            }
            if r.contains("..") {
                issues.append(.init(kind: .badLocalPath, detail: "\(desc) \"\(raw)\" escapes the project with \"..\"")); return
            }
            if r.hasPrefix("./") { r = String(r.dropFirst(2)) }
            if let q = r.firstIndex(where: { $0 == "?" || $0 == "#" }) { r = String(r[..<q]) }
            if r.isEmpty { return }
            if byName[r.lowercased()] == nil {
                issues.append(.init(kind: .missingLinkedFile,
                                    detail: "\(desc) points to \"\(raw)\" but no such file exists in the project"))
            }
        }
        // Only <link> stylesheets (.css) — skip icons/manifests/preconnect which legitimately have no bundled file.
        for href in matches(#"<link\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#, in: htmlBlob) where href.lowercased().hasSuffix(".css") {
            checkLocalRef(href, "a <link> stylesheet")
        }
        for src in matches(#"<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, in: htmlBlob) { checkLocalRef(src, "a <script src>") }
        for src in matches(#"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, in: htmlBlob) { checkLocalRef(src, "an <img>") }
        for src in matches(#"<source\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, in: htmlBlob) { checkLocalRef(src, "a media <source>") }
        let cssBlob = (cssFiles.map { $0.content } + matches(#"<style\b[^>]*>(.*?)</style>"#, in: htmlBlob)).joined(separator: "\n")
        for u in matches(#"url\(\s*['"]?([^'")]+)['"]?\s*\)"#, in: cssBlob) { checkLocalRef(u, "a CSS url()") }

        // --- Structure (per HTML document) ---
        for f in htmlFiles {
            let low = f.content.lowercased()
            if low.contains("<html") && !low.contains("</html>") { issues.append(.init(kind: .malformedStructure, detail: "\(f.path): has <html> but no closing </html>")) }
            if !low.contains("<body") { issues.append(.init(kind: .malformedStructure, detail: "\(f.path): no <body> element")) }
            else if !low.contains("</body>") { issues.append(.init(kind: .malformedStructure, detail: "\(f.path): <body> is never closed")) }
            var seen = Set<String>(), dups = Set<String>()
            for id in matches(#"\bid\s*=\s*["']([^"']+)["']"#, in: f.content) where !seen.insert(id).inserted { dups.insert(id) }
            for d in dups.sorted() { issues.append(.init(kind: .duplicateID, detail: "\(f.path): duplicate id=\"\(d)\" (ids must be unique)")) }
        }
        // --- Unresolved {{template}} placeholders anywhere ---
        for f in files where f.content.range(of: #"\{\{[^}]+\}\}"#, options: .regularExpression) != nil {
            issues.append(.init(kind: .unresolvedTemplate, detail: "\(f.path): contains an unresolved {{template}} placeholder"))
        }

        // --- Asset hygiene: a .css/.js file must be pure (not wrapped in <style>/<script>/HTML) AND actually
        //     referenced by the HTML (an orphaned stylesheet/script is dead code — e.g. a toggle that never runs). ---
        func normRef(_ s: String) -> String {
            var r = s.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("./") { r = String(r.dropFirst(2)) }
            if let q = r.firstIndex(where: { $0 == "?" || $0 == "#" }) { r = String(r[..<q]) }
            return r.lowercased()
        }
        let scriptSrcs = Set(matches(#"<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, in: htmlBlob).map(normRef))
        let linkHrefs = Set(matches(#"<link\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#, in: htmlBlob).map(normRef))
        let cssImports = Set(matches(#"@import\s+(?:url\()?\s*['"]?([^'")\s]+)"#, in: cssBlob).map(normRef))
        let multi = files.count > 1
        for f in files {
            let low = f.path.lowercased()
            let head = f.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if low.hasSuffix(".css") {
                if head.hasPrefix("<") {
                    issues.append(.init(kind: .malformedAsset, detail: "\(f.path): a CSS file must be pure CSS but is wrapped in HTML tags (e.g. <style>) — remove the tags"))
                }
                if multi, !linkHrefs.contains(low), !cssImports.contains(low) {
                    issues.append(.init(kind: .unreferencedFile, detail: "\(f.path): stylesheet is never linked from the HTML — add <link rel=\"stylesheet\" href=\"\(f.path)\">"))
                }
            } else if low.hasSuffix(".js") || low.hasSuffix(".mjs") {
                if head.hasPrefix("<") {
                    issues.append(.init(kind: .malformedAsset, detail: "\(f.path): a JavaScript file must be pure JS but is wrapped in HTML tags (e.g. <script>) — remove the tags"))
                }
                if multi, !scriptSrcs.contains(low) {
                    issues.append(.init(kind: .unreferencedFile, detail: "\(f.path): script is never included in the HTML — add <script src=\"\(f.path)\"></script>"))
                }
            }
        }
        // De-duplicate identical messages.
        var seenDetail = Set<String>()
        return issues.filter { seenDetail.insert($0.detail).inserted }
    }
}

/// Capability-specific, evidence-aware model-selection policy for project.generate. Benchmarks on this
/// machine (M1 Pro / 32 GB) showed Apple Foundation Models is the only RELIABLE local option but has a small
/// (~4 K) context window; larger installed models are unreliable (llama-3.2-3b: cross-file-broken output),
/// unusably slow (deepseek-r1-7b: ~8 min, reasoning overflow) or incompatible (qwen3.5-9b crashes in mlx_lm).
/// So: a small project fits Apple FM; a large one has no suitable on-device model → explain/clarify instead
/// of overflowing. If the user pins a (future-)compatible larger code model, that pin is honored.
public enum ProjectComplexity {
    public struct Estimate: Sendable {
        public let expectedFiles: Int
        public let expectedOutputTokens: Int
        public let isLarge: Bool
    }
    /// Apple FM's usable window is ~4 K tokens; after the system+user prompt this is the safe OUTPUT budget.
    static let appleSafeOutputTokens = 2600
    public static func estimate(_ prompt: String) -> Estimate {
        let p = prompt.lowercased()
        var files = 3   // index.html + style.css + script.js baseline
        for (kw, add) in [("multi-file", 1), ("multiple files", 1), ("separate files", 1), ("pages", 2),
                          ("dashboard", 2), ("catalog", 2), ("gallery", 2), ("product", 1), ("assets", 1),
                          ("several", 1), ("admin", 1), ("charts", 1), ("table", 1)] where p.contains(kw) {
            files += add
        }
        files = min(files, 8)
        let featureWords = ["nav", "navbar", "menu", "hero", "form", "modal", "carousel", "slider", "filter",
                            "search", "cart", "chart", "grid", "animation", "toggle", "tabs", "accordion",
                            "footer", "sidebar"]
        let features = featureWords.reduce(0) { $0 + (p.contains($1) ? 1 : 0) }
        // Rough output size: ~500 tokens/file + ~120/feature + a bounded prompt-length contribution.
        let tokens = files * 500 + features * 120 + min(prompt.count / 4, 400)
        return Estimate(expectedFiles: files, expectedOutputTokens: tokens, isLarge: tokens > appleSafeOutputTokens)
    }
}

public struct ProjectGenProvider: CapabilityProvider {
    public typealias InferFn = @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    public typealias StrongInferFn = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> (text: String, model: String)
    typealias Attempt = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> (String, String)

    /// At most this many consistency-repair round-trips AFTER the initial generation. Bounded on purpose —
    /// esh never runs an unbounded self-fixing agent loop.
    static let maxRepairAttempts = 2

    /// A model/runtime "context window exceeded" failure (so we can explain it instead of surfacing a 400).
    static func isContextWindowError(_ error: Error) -> Bool {
        error.localizedDescription.lowercased().contains("context window")
    }

    /// Pick the best installed LOCAL coding model for Tier-B generation, by metadata (NOT a hard-coded id):
    /// a text-only chat model whose name/id marks it as code-focused (coder/code/codestral/starcoder),
    /// preferring the largest (a proxy for capability). Returns nil when none is installed, so the caller
    /// falls back to its default behavior. Kept pure + static for unit testing.
    public static func bestCodingModelID(_ installs: [ModelInstall]) -> String? {
        let coders = installs.filter { inst in
            let s = inst.spec
            guard s.inputModalities == [.text] else { return false }        // text-only (exclude vision/VLM)
            guard s.capabilities.text?.supportsChat ?? false else { return false }
            let hay = (s.id + " " + s.displayName).lowercased()
            return hay.contains("coder") || hay.contains("codestral") || hay.contains("starcoder")
                || hay.contains("code-") || hay.contains("-code")
        }
        return coders.max(by: { $0.sizeBytes < $1.sizeBytes })?.id
    }

    /// Decode the model's file manifest, tolerating a common LLM serialization deviation: emitting the
    /// {"files":[…]} object with the string values delimited by BACKTICKS (JS template literals) instead of
    /// JSON double-quoted strings. This is a parsing-robustness step ONLY — every generated file still goes
    /// through the full security validation afterwards (deps/imports/CommonJS/addons); nothing is trusted here.
    static func decodeManifest(from raw: String) -> ProjectManifest? {
        if let json = TextToSVGProvider.extractJSONObject(raw),
           let m = try? JSONDecoder().decode(ProjectManifest.self, from: Data(json.utf8)) {
            return m
        }
        // Fallback: rewrite `…` template-literal values into valid JSON strings, then retry.
        let repaired = repairTemplateLiteralJSON(raw)
        guard repaired != raw, let json = TextToSVGProvider.extractJSONObject(repaired),
              let m = try? JSONDecoder().decode(ProjectManifest.self, from: Data(json.utf8)) else { return nil }
        return m
    }

    /// Convert JSON-value positions delimited by backticks (`: \`…\``) into properly escaped JSON strings.
    /// Scene/app code rarely contains a literal backtick, so a lazy match to the next backtick recovers the
    /// value; if it doesn't parse afterwards the caller still fails safely into bounded repair.
    static func repairTemplateLiteralJSON(_ s: String) -> String {
        guard s.contains("`") else { return s }
        guard let re = try? NSRegularExpression(pattern: ":\\s*`([\\s\\S]*?)`(?=\\s*[,}\\]])") else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        let mut = NSMutableString(string: s)
        for m in matches.reversed() {
            let inner = ns.substring(with: m.range(at: 1))
            let encoded = (try? String(data: JSONSerialization.data(withJSONObject: inner, options: [.fragmentsAllowed]),
                                       encoding: .utf8)) ?? "\"\""
            mut.replaceCharacters(in: m.range, with: ": " + encoded)
        }
        return mut as String
    }

    public let descriptor: CapabilityProviderDescriptor
    private let infer: InferFn
    private let strongInfer: StrongInferFn?
    private let preferStrongFirst: @Sendable () -> Bool
    /// Resolves the id of the best installed local CODING model for Tier-B (browser-native) generation, or nil
    /// when none is installed. Kept as a closure (resolved from the live catalog) so no model id is hard-coded
    /// in this provider — the interactive/browser-module tier prefers this model over Apple FM (whose ~4K
    /// window overflows on rich scenes); small static projects still prefer Apple FM.
    private let codingModel: @Sendable () -> String?

    public init(id: String = "project-generate", infer: @escaping InferFn,
                strongInfer: StrongInferFn? = nil, preferStrongFirst: @escaping @Sendable () -> Bool = { false },
                codingModel: @escaping @Sendable () -> String? = { nil }) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.projectGenerate], acceptedInputs: [.text], producedOutputs: [.text],
            backend: .native, modelFamily: nil, streaming: false, structuredOutput: true,
            requiredPrivilege: .previewSandboxed, previewMode: .staticSandbox)
        self.infer = infer; self.strongInfer = strongInfer; self.preferStrongFirst = preferStrongFirst
        self.codingModel = codingModel
    }

    static let systemInstruction = """
    You generate a SMALL multi-file static web project. Respond with ONLY a JSON object of this shape: \
    {"files":[{"path":"index.html","content":"..."},{"path":"style.css","content":"..."},{"path":"script.js","content":"..."}]}. \
    Rules: include an index.html entrypoint that references the other files by RELATIVE path (e.g. \
    <link rel="stylesheet" href="style.css">, <script src="script.js"></script>); keep it fully \
    self-contained — NO external CDNs/URLs/fonts/network; every element a script targets (getElementById / \
    querySelector('#id')) MUST exist in the HTML; every local file you link (stylesheet/script/img) MUST be \
    one of the files you return, AND every .css/.js file you return MUST be linked from index.html; a .css \
    file's content is PURE CSS and a .js file's content is PURE JavaScript — do NOT wrap them in <style> or \
    <script> tags; paths must be simple relative names (no "/" prefix, no ".."). No markdown fences, no prose \
    — ONLY the JSON.
    """

    /// Build the (system, user) repair prompt: the current manifest + the specific consistency issues to fix.
    static func repairPrompt(files: [(path: String, content: String)], issues: [ProjectConsistency.Issue]) -> (String, String) {
        let manifest = ProjectManifest(files: files.map { ProjectFile(path: $0.path, content: $0.content) })
        let json = (try? String(data: JSONEncoder().encode(manifest), encoding: .utf8)) ?? "{}"
        let bullets = issues.map { "- \($0.detail)" }.joined(separator: "\n")
        let user = """
        The generated project has these consistency problems:

        \(bullets)

        Here is the current project manifest as JSON:
        \(json)

        Fix ONLY these project-consistency problems (add the missing element(s), add or correct the missing \
        local file(s), or remove the dangling reference — whichever keeps the project self-contained). Do NOT \
        redesign unrelated content and keep every other file unchanged. Return the FULL corrected project as \
        the same JSON object {"files":[...]}. No markdown fences, no prose — ONLY the JSON.
        """
        return (systemInstruction, user)
    }

    /// Tier-B system prompt: the model writes ONLY the app logic (app.js + optional style.css). esh owns
    /// index.html, the import map, and the bootstrap — so generated code can never set the security policy.
    static func browserModuleSystemInstruction(approved: [String]) -> String {
        let libs = approved.isEmpty ? "(none available)" : approved.joined(separator: ", ")
        return """
        You write the application logic for a small BROWSER-NATIVE interactive project that runs as a NATIVE \
        browser ES MODULE. Respond with ONLY a JSON object of this shape: \
        {"files":[{"path":"app.js","content":"..."},{"path":"style.css","content":"..."}]} (style.css optional). \
        Rules: write an ES module app.js that renders into the EXISTING element document.getElementById('app') — \
        esh provides index.html, the import map and the module bootstrap, so do NOT write index.html or an \
        import map. Use ES MODULE syntax ONLY — `import * as THREE from "three";` — and NEVER Node/CommonJS \
        (no require(), no module.exports); this runs directly in the browser, not Node. Import approved \
        libraries ONLY by BARE specifier. Available libraries: \(libs). NEVER import from a URL/CDN/path (no \
        "https://…", no "./file.js"). Actually CREATE the requested objects (geometry, meshes, lights) and an \
        animation loop with requestAnimationFrame so something visibly renders. NO network of any kind: no \
        fetch/XHR/WebSocket, no external images/textures/fonts — use PROCEDURAL / generated visuals only so it \
        works fully offline. app.js is PURE JavaScript and style.css is PURE CSS (no <script>/<style> tags, no \
        markdown fences). Return ONLY the JSON object.
        """
    }

    /// Three.js scene-contract prompt: esh owns the renderer/scene/camera/lights/loop; the model writes only
    /// scene content. This keeps output small + reliable (fits the on-device model even for rich scenes).
    static let threeJSSystemInstruction = """
    You write ONLY the scene content for a Three.js project. esh already provides index.html and, as GLOBALS: \
    THREE, scene, camera (at z=5 looking at the origin), renderer, plus a full-window render loop and lights. \
    Respond with ONLY a JSON object: {"files":[{"path":"app.js","content":"..."},{"path":"style.css","content":"..."}]} \
    (style.css optional). In app.js: build objects with THREE and ADD them to the EXISTING global `scene` via \
    scene.add(...). Do NOT create a renderer, camera, scene, or animation loop and do NOT call renderer.render — \
    esh runs the loop. For animation assign globalThis.eshTick = (dt) => { /* runs each frame, dt seconds */ }. \
    For controls (pause, toggle) create <button> elements, append them to a <div class="ui"> you add to \
    document.body, and wire click handlers that flip simple boolean flags your eshTick reads. Use ONLY CORE \
    THREE classes (Scene, Mesh, *Geometry, MeshStandardMaterial/MeshBasicMaterial, lights, Group, Vector3, \
    Color) — do NOT use THREE.OrbitControls or ANY addon/example/loader class (they are NOT available); if you \
    want the camera or object to move, rotate your object inside eshTick instead. Use ONLY procedural \
    geometry/colors/math — NO network, NO external textures/images/fonts, NO fetch, NO require()/module.exports, \
    NO URL/CDN imports. THREE is a global so no import is needed. app.js is PURE JavaScript, style.css PURE CSS \
    (no <script>/<style> tags, no markdown). CRITICAL JSON FORMAT: each "content" value MUST be a standard \
    JSON string in DOUBLE QUOTES with newlines escaped as \\n and inner double-quotes as \\" — NEVER use \
    backticks or template literals to delimit the content, and NEVER wrap the reply in markdown code fences. \
    Return ONLY the JSON object.
    """

    /// Tier-B (browser-native) generation: model writes app logic → esh resolves approved vendored deps →
    /// esh scaffolds index.html + import map → validated, self-contained `.webProject` v2 artifact.
    func browserModuleStream(_ request: ResolvedExecutionRequest, projectType: ProjectType,
                             context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let infer = self.infer
        let strongInfer = self.strongInfer
        let preferStrongFirst = self.preferStrongFirst
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    cont.yield(.status("composing interactive project"))
                    let prompt = req.inputs.compactMap { input -> String? in
                        if case .text(let t) = input.payload { return t }; return nil
                    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    let userPrompt = prompt.isEmpty ? "a small interactive browser project" : prompt
                    let maxTokens = TextToSVGProvider.intOption(req, "maxTokens") ?? 4000
                    let cacheRoot = context.root.cachesURL.appendingPathComponent("web-libs", isDirectory: true)
                    let resolver = DependencyResolver(cacheRoot: cacheRoot)

                    // Tier B prefers a real local CODING model (large context, competent JS) over Apple FM,
                    // whose ~4K window overflows on rich interactive scenes. Use the explicitly-pinned model if
                    // any, else the best installed coding model resolved from the live catalog.
                    let tierBModel = req.model ?? self.codingModel()
                    let localAttempt: Attempt = { sys, user, maxT in
                        let r = try await infer(ExternalInferenceRequest(
                            model: tierBModel,
                            messages: [ExternalInferenceMessage(role: .system, text: sys),
                                       ExternalInferenceMessage(role: .user, text: user)],
                            generation: GenerationConfig(maxTokens: maxT, temperature: 0.4), responseFormat: .json))
                        return (ThinkingParser.parse(r.outputText).answer ?? r.outputText, r.modelID)
                    }
                    var strongAttempt: Attempt? = nil
                    if let s = strongInfer { strongAttempt = { sys, user, maxT in try await s(sys, user, min(maxT, 3000)) } }
                    // A capable coding model is available (pinned or resolved) → try it FIRST for Tier B, with
                    // Apple FM only as a fallback. Fall back to the previous ordering when none is installed.
                    var attempts: [Attempt] = []
                    if tierBModel != nil { attempts = [localAttempt]; if let st = strongAttempt { attempts.append(st) } }
                    else if preferStrongFirst(), let st = strongAttempt { attempts = [st, localAttempt] }
                    else { attempts = [localAttempt]; if let st = strongAttempt { attempts.append(st) } }

                    let sysInstruction = (projectType == .threejs)
                        ? Self.threeJSSystemInstruction
                        : Self.browserModuleSystemInstruction(approved: WebLibRegistry.approvedNames)

                    // Validate a candidate file set → (issues, resolution). Issues drive bounded repair.
                    func validate(_ files: [(path: String, content: String)]) -> ([String], DependencyResolution) {
                        var issues: [String] = []
                        let jsFiles = files.filter { $0.path.lowercased().hasSuffix(".js") }
                        guard !jsFiles.isEmpty else {
                            return (["no app.js entry module"], DependencyResolution(resolved: [], importMap: [:], bundleFiles: [:], rejected: []))
                        }
                        for f in files where ProjectValidator.isPlaceholder(f.content) { issues.append("\(f.path): placeholder/empty content") }
                        let returned = Set(files.map { $0.path.lowercased() })
                        var bareSpecs: [String] = []
                        for f in jsFiles {
                            // Reject Node/CommonJS — this runs as a native browser ES module.
                            if f.content.range(of: #"\brequire\s*\(\s*["']"#, options: .regularExpression) != nil {
                                issues.append("\(f.path): uses CommonJS require() — use ES module syntax instead, e.g. import * as THREE from \"three\"")
                            }
                            if f.content.range(of: #"\bmodule\.exports\b|\bexports\.\w"#, options: .regularExpression) != nil {
                                issues.append("\(f.path): uses CommonJS module.exports — use ES module import/export syntax")
                            }
                            // Three.js addons (OrbitControls, loaders, etc.) are NOT in the core bundle — reject.
                            if let m = f.content.range(of: #"THREE\.(OrbitControls|TrackballControls|GLTFLoader|OBJLoader|FBXLoader|TextureLoader|FontLoader|EffectComposer|[A-Za-z]+Controls|[A-Za-z]+Loader)"#, options: .regularExpression) {
                                issues.append("\(f.path): uses \(f.content[m]) — Three.js addons/examples are not available; use only CORE THREE and rotate objects inside globalThis.eshTick")
                            }
                            for ref in BrowserModuleComposer.imports(inJS: f.content) {
                                switch ref.kind {
                                case .url:
                                    issues.append("\(f.path): remote import \"\(ref.specifier)\" is not allowed — import the approved library by bare name (e.g. \"three\")")
                                case .relative:
                                    var t = ref.specifier
                                    if t.hasPrefix("./") { t = String(t.dropFirst(2)) }
                                    if !returned.contains(t.lowercased()) { issues.append("\(f.path): import \"\(ref.specifier)\" points to a missing local file") }
                                case .bare:
                                    bareSpecs.append(ref.specifier)
                                }
                            }
                        }
                        // A bare import to something NOT in the curated registry is rejected outright.
                        for spec in bareSpecs where !resolver.registry.contains(where: { $0.id.lowercased() == spec.lowercased() }) {
                            issues.append("dependency \"\(spec)\" is not an approved library — remove it or use an approved one (\(WebLibRegistry.approvedNames.joined(separator: ", ")))")
                        }
                        // Resolve libraries the code actually USES (bare import of the id, or the library global
                        // such as THREE.…). esh vendors + exposes them; a used-but-not-vendored lib is rejected.
                        let usedIDs = resolver.usedLibIDs(in: jsFiles.map { $0.content })
                        let res = resolver.resolve(usedIDs)
                        for r in res.rejected { issues.append("dependency \"\(r)\" is used but not vendored offline — run scripts/vendor-web-libs.sh to provision it") }
                        return (issues, res)
                    }

                    var appFiles: [(path: String, content: String)]?
                    var resolution = DependencyResolution(resolved: [], importMap: [:], bundleFiles: [:], rejected: [])
                    var usedModel = req.model ?? "unknown"
                    var repairAttempts = 0
                    var lastError: Error?
                    outer: for (i, attempt) in attempts.enumerated() {
                        if i > 0 { cont.yield(.status("retrying with a more reliable model")) }
                        var user = userPrompt
                        for pass in 0..<2 {
                            if Task.isCancelled { throw CancellationError() }
                            do {
                                let (raw, model) = try await attempt(sysInstruction, user, maxTokens)
                                if let manifest = Self.decodeManifest(from: raw) {
                                    let files = manifest.files.map { (path: $0.path, content: $0.content) }
                                    let (issues, res) = validate(files)
                                    if issues.isEmpty { appFiles = files; resolution = res; usedModel = model; break outer }
                                    if pass == 0 {
                                        repairAttempts += 1
                                        cont.yield(.status("repairing (attempt \(repairAttempts))"))
                                        user = userPrompt + "\n\nYour previous reply had these problems:\n"
                                            + issues.map { "- \($0)" }.joined(separator: "\n")
                                            + "\n\nReturn ONLY the corrected JSON. Import approved libraries by bare name only; no URLs, no network."
                                    }
                                } else if pass == 0 {
                                    user = userPrompt + "\n\nYour previous reply was not valid JSON of {\"files\":[…]} with an app.js. Reply again with ONLY the JSON."
                                }
                            } catch { lastError = error; break }
                        }
                    }
                    guard let files = appFiles else {
                        if let e = lastError, Self.isContextWindowError(e) {
                            throw CapabilityError.failed("This interactive project is likely too large for the on-device model's context window. Try a simpler scene, or pin a larger compatible local code model.")
                        }
                        throw lastError ?? CapabilityError.failed("The model did not produce a valid browser-module project (app.js) using only approved offline dependencies.")
                    }

                    // Compose the bundle: esh scaffold + model files + vendored libs (integrity re-verified).
                    cont.yield(.status("resolving local dependencies"))
                    let appEntry = files.first { $0.path.lowercased() == "app.js" }?.path
                        ?? files.first { $0.path.lowercased().hasSuffix(".js") }?.path ?? "app.js"
                    let hasStyle = files.contains { $0.path.lowercased() == "style.css" }
                    var payload: [String: Data] = [:]
                    for f in files where f.path.lowercased() != "index.html" { payload[f.path] = Data(f.content.utf8) }
                    for (bundlePath, absPath) in resolution.bundleFiles {
                        let expected = resolution.resolved.first(where: { bundlePath.contains("/\($0.name)/") })?.integritySHA256
                        payload[bundlePath] = try WebLibVendor.bytes(at: absPath, expectedSHA256: expected)
                    }
                    // Expose each resolved library's conventional global (e.g. three → THREE) so natural
                    // global-style generated code works; the ESM specifier stays available via the import map.
                    var globals: [(specifier: String, global: String)] = []
                    for dep in resolution.resolved {
                        if let lib = WebLibRegistry.entry(for: dep.name), let g = lib.globalName {
                            globals.append((lib.files.first?.importSpecifier ?? lib.id, g))
                        }
                    }
                    let title = String(userPrompt.prefix(60))
                    let indexHTML: String
                    if projectType == .threejs, resolution.importMap["three"] != nil {
                        // esh owns the Three.js renderer/scene/camera/loop; the model supplied only scene content.
                        indexHTML = BrowserModuleComposer.scaffoldThreeJSIndexHTML(
                            title: title, importMap: resolution.importMap, hasStyle: hasStyle, appEntry: appEntry)
                    } else {
                        indexHTML = BrowserModuleComposer.scaffoldIndexHTML(
                            title: title, importMap: resolution.importMap, globals: globals,
                            hasStyle: hasStyle, appEntry: appEntry)
                    }
                    payload["index.html"] = Data(indexHTML.utf8)

                    cont.yield(.status("validating"))
                    let manifest = ProjectManifestV2(
                        projectType: projectType,
                        runtimeRequirements: RuntimeRequirements(kind: .browserModule, importMap: resolution.importMap),
                        dependencies: resolution.resolved,
                        permissions: .sandboxedNoNetwork,
                        previewConfiguration: PreviewConfig(previewMode: .managed, privilege: .previewSandboxed,
                                                            sandboxFlags: ["allow-scripts"], csp: nil))
                    let totalBytes = payload.values.reduce(0) { $0 + $1.count }
                    func stage(_ ok: Bool) -> JSONValue { .string(ok ? "passed" : "failed") }
                    let report: JSONValue = .object([
                        "pathSafety": stage(true), "mimeTypes": stage(true), "entrypoint": stage(true),
                        "contentQuality": stage(true), "dependencies": stage(resolution.rejected.isEmpty),
                        "moduleImports": stage(true), "securityPolicy": stage(true),
                        "crossFileReferences": stage(true), "repairAttempts": .int(repairAttempts)])
                    let depList = resolution.resolved.map { "\($0.name)@\($0.version)" }
                    var meta: [String: JSONValue] = [
                        "fileCount": .int(payload.count), "byteSize": .int(totalBytes), "selfContained": .bool(true),
                        "repairAttempts": .int(repairAttempts), "validation": report,
                        "files": .array(payload.keys.sorted().map { .string($0) }),
                        "dependencies": .array(depList.map { .string($0) })]
                    if let pj = try? manifest.asJSONValue() { meta[ProjectManifestV2.metadataKey] = pj }
                    let artifact = Artifact(
                        kind: .webProject, mimeType: "text/html", entrypoint: "index.html", metadata: meta,
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: usedModel, capability: .projectGenerate),
                        validation: ArtifactValidation(isValid: true, findings: []),
                        preview: PreviewDescriptor(mode: .managed, privilege: .previewSandboxed))
                    let saved = try context.artifactStore.save(artifact, files: payload)
                    cont.yield(.planResolved(ExecutionPlan.single(
                        capability: req.capability, inputModalities: [.text], outputModality: .text,
                        providerID: providerID, modelID: usedModel, backend: .native,
                        rationale: [
                            "Generated a Tier-B browser-native (\(projectType.rawValue)) project (\(usedModel)) — esh-owned scaffold + import map, previewed in an isolated sandbox.",
                            "Dependencies (vendored, pinned, integrity-verified): \(depList.isEmpty ? "none" : depList.joined(separator: ", ")).",
                            "Network denied by default (connect-src 'none'); no external imports/CDNs; repairs: \(repairAttempts)."])))
                    cont.yield(.artifactProduced(saved))
                    cont.yield(.previewReady(url: "/v1/artifacts/\(saved.id.uuidString)/index.html"))
                    cont.yield(.done(finishReason: "stop"))
                    cont.finish()
                } catch is CancellationError {
                    cont.yield(.failed(message: "interactive project generation was cancelled")); cont.finish(throwing: CancellationError())
                } catch {
                    cont.yield(.failed(message: error.localizedDescription)); cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        // Tier B (browser-native / Three.js) is a distinct, self-contained flow so the production static path
        // below is untouched. Gated by the router-set ExecutionOptions["projectType"].
        if let tierBType = BrowserModuleComposer.requestedTierBType(request.request) {
            return browserModuleStream(request, projectType: tierBType, context: context)
        }
        let req = request.request
        let infer = self.infer
        let strongInfer = self.strongInfer
        let preferStrongFirst = self.preferStrongFirst
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    cont.yield(.status("composing project"))
                    let prompt = req.inputs.compactMap { input -> String? in
                        if case .text(let t) = input.payload { return t }; return nil
                    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    let userPrompt = prompt.isEmpty ? "a small static website" : prompt
                    let maxTokens = TextToSVGProvider.intOption(req, "maxTokens") ?? 4000

                    // --- Evidence-aware model selection (exposed in the ExecutionPlan) ---
                    let estimate = ProjectComplexity.estimate(userPrompt)
                    let pinned = !preferStrongFirst()                 // a non-"auto" capability pin is set
                    let selectionPrimary: String
                    let selectionReason: String
                    if pinned {
                        selectionPrimary = req.model ?? "pinned model"
                        selectionReason = "user-pinned model for project.generate (honored for any size)"
                    } else if estimate.isLarge {
                        selectionPrimary = "apple-foundation"
                        selectionReason = "large project (~\(estimate.expectedFiles) files, ~\(estimate.expectedOutputTokens) tok est.) — "
                            + "no larger on-device code model is installed/compatible; attempting Apple FM but it may not fit"
                    } else {
                        selectionPrimary = "apple-foundation"
                        selectionReason = "small project (~\(estimate.expectedFiles) files, ~\(estimate.expectedOutputTokens) tok est.) fits Apple FM's window"
                    }

                    let localAttempt: Attempt = { sys, user, maxT in
                        let response = try await infer(ExternalInferenceRequest(
                            model: req.model,
                            messages: [ExternalInferenceMessage(role: .system, text: sys),
                                       ExternalInferenceMessage(role: .user, text: user)],
                            generation: GenerationConfig(maxTokens: maxT, temperature: 0.4), responseFormat: .json))
                        return (ThinkingParser.parse(response.outputText).answer ?? response.outputText, response.modelID)
                    }
                    // Apple FM has a small (~4K) context window: reserving the full output budget overflows it
                    // (input + reserved output > window). Clamp the strong attempt so a small 3-file project
                    // still fits comfortably; the local model keeps the larger budget.
                    var strongAttempt: Attempt? = nil
                    if let s = strongInfer {
                        strongAttempt = { sys, user, maxT in try await s(sys, user, min(maxT, 3000)) }
                    }
                    var attempts: [Attempt] = []
                    if preferStrongFirst(), let strongAttempt {
                        attempts = [strongAttempt, localAttempt]
                    } else {
                        attempts = [localAttempt]
                        if let strongAttempt { attempts.append(strongAttempt) }
                    }

                    var files: [(path: String, content: String)]?
                    var validation = ArtifactValidation.notValidated
                    var usedModel = req.model ?? "unknown"
                    var winner: Attempt?
                    var lastError: Error?
                    outer: for (i, attempt) in attempts.enumerated() {
                        if i > 0 { cont.yield(.status("retrying with a more reliable model")) }
                        var user = userPrompt
                        for pass in 0..<2 {
                            if Task.isCancelled { throw CancellationError() }
                            do {
                                let (raw, model) = try await attempt(Self.systemInstruction, user, maxTokens)
                                if let manifest = Self.decodeManifest(from: raw) {
                                    let (safe, v) = ProjectValidator.validate(manifest.files.map { ($0.path, $0.content) })
                                    if v.isValid { files = safe; validation = v; usedModel = model; winner = attempt; break outer }
                                }
                                if pass == 0 {
                                    user = userPrompt + "\n\nYour previous reply was not a valid project JSON with an "
                                        + "index.html. Reply again with ONLY the JSON object described above."
                                }
                            } catch { lastError = error; break }
                        }
                    }
                    guard var files, let winner else {
                        // Predictable overflow handling: a context-window error on a large project is not a
                        // mysterious 400 — explain it and give the actionable next step (item 11 of the gate).
                        if let e = lastError, Self.isContextWindowError(e) {
                            throw CapabilityError.failed(
                                "This project is likely too large for the on-device model's context window "
                                + "(~\(estimate.expectedFiles) files, ~\(estimate.expectedOutputTokens) tokens estimated). "
                                + "Try a smaller or simpler project, or pin a larger compatible local code model for "
                                + "project.generate — no larger on-device code model is currently installed and compatible.")
                        }
                        throw lastError ?? CapabilityError.failed("The model did not produce a valid multi-file project.")
                    }

                    // Layer 2 — cross-file consistency + bounded repair. generate → check → repair(≤N) → re-check.
                    cont.yield(.status("validating project consistency"))
                    var issues = ProjectConsistency.check(files)
                    var repairAttempts = 0
                    while !issues.isEmpty && repairAttempts < Self.maxRepairAttempts {
                        if Task.isCancelled { throw CancellationError() }
                        repairAttempts += 1
                        cont.yield(.status("repairing project consistency (attempt \(repairAttempts))"))
                        do {
                            let (sys, user) = Self.repairPrompt(files: files, issues: issues)
                            let (raw, model) = try await winner(sys, user, maxTokens)
                            guard let manifest = Self.decodeManifest(from: raw) else { break }
                            let (safe, v) = ProjectValidator.validate(manifest.files.map { ($0.path, $0.content) })
                            guard v.isValid else { break }
                            let newIssues = ProjectConsistency.check(safe)
                            // Accept the repair ONLY if it strictly reduces the problem set (never regress).
                            guard newIssues.count < issues.count else { break }
                            files = safe; validation = v; usedModel = model; issues = newIssues
                        } catch { break }   // repair error (e.g. context overflow) → keep the best valid version
                    }

                    let crossRefOK = issues.isEmpty
                    let overallValid = validation.isValid && crossRefOK
                    let findings = validation.findings + issues.map { $0.detail }

                    cont.yield(.status("saving"))
                    var payload: [String: Data] = [:]
                    for f in files { payload[f.path] = Data(f.content.utf8) }
                    let totalBytes = payload.values.reduce(0) { $0 + $1.count }
                    // Structured, stage-by-stage validation report for the Execution Inspector (hidden from normal UX).
                    func stage(_ ok: Bool) -> JSONValue { .string(ok ? "passed" : "failed") }
                    let pathSafetyOK = !validation.findings.contains { $0.contains("unsafe path") }
                        && !issues.contains { $0.kind == .badLocalPath }
                    let contentQualityOK = validation.isValid && !validation.findings.contains { $0.contains("placeholder") }
                        && !issues.contains { $0.kind == .malformedAsset }
                    let report: JSONValue = .object([
                        "pathSafety": stage(pathSafetyOK),
                        "mimeTypes": stage(true),               // served per-extension by construction
                        "entrypoint": stage(validation.isValid),
                        "contentQuality": stage(contentQualityOK),
                        "crossFileReferences": stage(crossRefOK),
                        "repairAttempts": .int(repairAttempts)])
                    let artifact = Artifact(
                        kind: .webProject, mimeType: "text/html", entrypoint: "index.html",
                        metadata: ["fileCount": .int(files.count), "byteSize": .int(totalBytes),
                                   "selfContained": .bool(validation.findings.allSatisfy { !$0.contains("external") }),
                                   "repairAttempts": .int(repairAttempts),
                                   "validation": report,
                                   "selection": .object([
                                       "expectedFiles": .int(estimate.expectedFiles),
                                       "expectedOutputTokens": .int(estimate.expectedOutputTokens),
                                       "sizeTier": .string(estimate.isLarge ? "large" : "small"),
                                       "primary": .string(selectionPrimary),
                                       "reason": .string(selectionReason),
                                       "actualModel": .string(usedModel)]),
                                   "files": .array(files.map { .string($0.path) })],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: usedModel, capability: .projectGenerate),
                        validation: ArtifactValidation(isValid: overallValid, findings: findings), preview: .staticSandbox)
                    let saved = try context.artifactStore.save(artifact, files: payload)
                    var rationale = ["Generated a \(files.count)-file static web project (\(usedModel)) — previewed in an isolated sandbox.",
                                     "Model selection: primary \(selectionPrimary) — \(selectionReason).",
                                     "Files: \(files.map { $0.path }.joined(separator: ", ")). No build/npm/network — static, self-contained."]
                    if repairAttempts > 0 { rationale.append("Cross-file consistency repaired in \(repairAttempts) pass(es).") }
                    if !crossRefOK { rationale.append("Remaining consistency issues: \(issues.map { $0.detail }.joined(separator: "; ")).") }
                    cont.yield(.planResolved(ExecutionPlan.single(
                        capability: req.capability, inputModalities: [.text], outputModality: .text,
                        providerID: providerID, modelID: usedModel, backend: .native, rationale: rationale)))
                    cont.yield(.artifactProduced(saved))
                    cont.yield(.done(finishReason: overallValid ? "stop" : "invalid"))
                    cont.finish()
                } catch is CancellationError {
                    cont.yield(.failed(message: "project generation was cancelled")); cont.finish(throwing: CancellationError())
                } catch {
                    cont.yield(.failed(message: error.localizedDescription)); cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
