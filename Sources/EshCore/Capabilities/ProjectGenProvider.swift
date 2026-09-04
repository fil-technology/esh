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

    public let descriptor: CapabilityProviderDescriptor
    private let infer: InferFn
    private let strongInfer: StrongInferFn?
    private let preferStrongFirst: @Sendable () -> Bool

    public init(id: String = "project-generate", infer: @escaping InferFn,
                strongInfer: StrongInferFn? = nil, preferStrongFirst: @escaping @Sendable () -> Bool = { false }) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.projectGenerate], acceptedInputs: [.text], producedOutputs: [.text],
            backend: .native, modelFamily: nil, streaming: false, structuredOutput: true,
            requiredPrivilege: .previewSandboxed, previewMode: .staticSandbox)
        self.infer = infer; self.strongInfer = strongInfer; self.preferStrongFirst = preferStrongFirst
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

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
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
                                if let json = TextToSVGProvider.extractJSONObject(raw),
                                   let manifest = try? JSONDecoder().decode(ProjectManifest.self, from: Data(json.utf8)) {
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
                            guard let json = TextToSVGProvider.extractJSONObject(raw),
                                  let manifest = try? JSONDecoder().decode(ProjectManifest.self, from: Data(json.utf8)) else { break }
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
