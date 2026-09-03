import Foundation

// esh 2.1 UCMR, Stage 1 — the text→SVG reference capability. The LLM emits a constrained JSON "scene
// IR"; a DETERMINISTIC Swift renderer compiles it to guaranteed-valid, whitelist-only SVG. This
// eliminates SVG sanitization at the source (only known-safe elements/attributes are ever emitted) and
// makes the capability independent of the generation method. See docs/UCMR_ARCHITECTURE.md §11.

/// A safe, LLM-friendly vector scene. Flat elements with a `type` discriminator (natural for a model
/// to emit) and a whitelisted attribute set.
public struct SVGScene: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var background: String?
    public var elements: [SVGSceneElement]

    public init(width: Int, height: Int, background: String? = nil, elements: [SVGSceneElement]) {
        self.width = width
        self.height = height
        self.background = background
        self.elements = elements
    }

    private enum CodingKeys: String, CodingKey { case width, height, background, elements }

    // Lenient decode: the model may omit dimensions; default to a square canvas.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 512
        self.height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 512
        self.background = try c.decodeIfPresent(String.self, forKey: .background)
        self.elements = try c.decodeIfPresent([SVGSceneElement].self, forKey: .elements) ?? []
    }
}

public struct SVGSceneElement: Codable, Sendable, Equatable {
    public var type: String       // rect|circle|ellipse|line|polyline|polygon|path|text
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var rx: Double?
    public var ry: Double?
    public var cx: Double?
    public var cy: Double?
    public var r: Double?
    public var x1: Double?
    public var y1: Double?
    public var x2: Double?
    public var y2: Double?
    public var points: String?
    public var d: String?
    public var text: String?
    public var fontSize: Double?
    public var fontFamily: String?
    public var textAnchor: String?
    public var fill: String?
    public var stroke: String?
    public var strokeWidth: Double?
    public var opacity: Double?
    public var transform: String?

    public init(type: String) { self.type = type }
}

/// Compiles an `SVGScene` to safe SVG. Only whitelisted elements/attributes are emitted; all values are
/// sanitized. Never emits <script>/<foreignObject>/<image>/<use>, event handlers, or external refs.
public enum SVGSceneRenderer {
    public static let maxDimension = 4096
    private static let maxCoordinate = 1_000_000.0

    public static func render(_ scene: SVGScene) -> String {
        let w = clampDimension(scene.width)
        let h = clampDimension(scene.height)
        var body = ""
        if let bg = safeColor(scene.background) {
            body += "<rect x=\"0\" y=\"0\" width=\"\(w)\" height=\"\(h)\" fill=\"\(bg)\"/>"
        }
        for element in scene.elements {
            if let rendered = renderElement(element) { body += rendered }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">\(body)</svg>"
    }

    private static func renderElement(_ e: SVGSceneElement) -> String? {
        let common = presentationAttributes(e)
        switch e.type.lowercased() {
        case "rect":
            guard let x = num(e.x), let y = num(e.y), let w = num(e.width), let h = num(e.height) else { return nil }
            var a = "x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\""
            if let rx = num(e.rx) { a += " rx=\"\(rx)\"" }
            if let ry = num(e.ry) { a += " ry=\"\(ry)\"" }
            return "<rect \(a)\(common)/>"
        case "circle":
            guard let cx = num(e.cx), let cy = num(e.cy), let r = num(e.r) else { return nil }
            return "<circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(r)\"\(common)/>"
        case "ellipse":
            guard let cx = num(e.cx), let cy = num(e.cy), let rx = num(e.rx), let ry = num(e.ry) else { return nil }
            return "<ellipse cx=\"\(cx)\" cy=\"\(cy)\" rx=\"\(rx)\" ry=\"\(ry)\"\(common)/>"
        case "line":
            guard let x1 = num(e.x1), let y1 = num(e.y1), let x2 = num(e.x2), let y2 = num(e.y2) else { return nil }
            return "<line x1=\"\(x1)\" y1=\"\(y1)\" x2=\"\(x2)\" y2=\"\(y2)\"\(common)/>"
        case "polyline", "polygon":
            guard let pts = safePoints(e.points) else { return nil }
            return "<\(e.type.lowercased()) points=\"\(pts)\"\(common)/>"
        case "path":
            guard let d = safePathData(e.d) else { return nil }
            return "<path d=\"\(d)\"\(common)/>"
        case "text":
            guard let x = num(e.x), let y = num(e.y), let t = e.text, !t.isEmpty else { return nil }
            var a = "x=\"\(x)\" y=\"\(y)\""
            if let fs = num(e.fontSize) { a += " font-size=\"\(fs)\"" }
            if let ff = safeToken(e.fontFamily) { a += " font-family=\"\(ff)\"" }
            if let ta = safeEnum(e.textAnchor, ["start", "middle", "end"]) { a += " text-anchor=\"\(ta)\"" }
            return "<text \(a)\(common)>\(escapeText(t))</text>"
        default:
            return nil
        }
    }

    private static func presentationAttributes(_ e: SVGSceneElement) -> String {
        var a = ""
        if let fill = safeColor(e.fill) { a += " fill=\"\(fill)\"" }
        if let stroke = safeColor(e.stroke) { a += " stroke=\"\(stroke)\"" }
        if let sw = num(e.strokeWidth) { a += " stroke-width=\"\(sw)\"" }
        if let op = e.opacity, op.isFinite { a += " opacity=\"\(clampUnit(op))\"" }
        if let tr = safeTransform(e.transform) { a += " transform=\"\(tr)\"" }
        return a
    }

    // MARK: - Sanitizers

    private static func clampDimension(_ v: Int) -> Int { min(max(v, 1), maxDimension) }
    private static func clampUnit(_ v: Double) -> Double { min(max(v, 0), 1) }

    private static func num(_ v: Double?) -> String? {
        guard let v, v.isFinite, abs(v) <= maxCoordinate else { return nil }
        // Trim trailing ".0" for integers; otherwise up to 3 decimals.
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.3f", v)
    }

    /// #rgb / #rrggbb(aa), rgb()/rgba(), or a plain color word. Rejects url()/javascript:/expressions.
    static func safeColor(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.count > 32 { return nil }
        let hex = "#[0-9a-fA-F]{3,8}"
        let word = "[a-zA-Z]{1,20}"
        let rgb = "rgba?\\([0-9.,%\\s]{1,40}\\)"
        let pattern = "^(\(hex)|\(word)|\(rgb)|none)$"
        return s.range(of: pattern, options: .regularExpression) != nil ? s : nil
    }

    static func safePoints(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.count <= 20_000 else { return nil }
        return s.range(of: "^[0-9eE.,\\-\\s]+$", options: .regularExpression) != nil ? s : nil
    }

    static func safePathData(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.count <= 50_000 else { return nil }
        // Only path commands + numbers/whitespace/separators.
        return s.range(of: "^[MmLlHhVvCcSsQqTtAaZz0-9eE.,\\-\\s]+$", options: .regularExpression) != nil ? s : nil
    }

    static func safeTransform(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.count <= 200 else { return nil }
        let fn = "(translate|rotate|scale|matrix|skewX|skewY)\\([-0-9.,\\s]*\\)"
        return s.range(of: "^(\(fn)\\s*)+$", options: .regularExpression) != nil ? s : nil
    }

    static func safeToken(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.count <= 60 else { return nil }
        return s.range(of: "^[a-zA-Z0-9 ,\\-]+$", options: .regularExpression) != nil ? s : nil
    }

    private static func safeEnum(_ raw: String?, _ allowed: [String]) -> String? {
        guard let s = raw?.lowercased() else { return nil }
        return allowed.contains(s) ? s : nil
    }

    static func escapeText(_ s: String) -> String {
        s.unicodeScalars.reduce(into: "") { acc, scalar in
            switch scalar {
            case "&": acc += "&amp;"
            case "<": acc += "&lt;"
            case ">": acc += "&gt;"
            case "\"": acc += "&quot;"
            case "'": acc += "&#39;"
            default:
                // Drop control characters; keep normal text.
                if scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" { acc.unicodeScalars.append(scalar) }
            }
        }
    }
}

/// Structural safety/validity check for rendered SVG (defense in depth even though the renderer only
/// emits safe output). Confirms well-formed XML, an <svg> root, no dangerous constructs, bounded size.
public enum SVGValidator {
    public static func validate(_ svg: String, expectedWidth: Int, expectedHeight: Int) -> ArtifactValidation {
        var findings: [String] = []
        let lower = svg.lowercased()
        for bad in ["<script", "<foreignobject", "<use", "<image", "javascript:", "onload=", "onclick=", "<!doctype", "<!entity", "xlink:href", " href="] {
            if lower.contains(bad) { findings.append("contains disallowed construct: \(bad)") }
        }
        if !svg.hasPrefix("<svg") { findings.append("root element is not <svg>") }
        if svg.utf8.count > 2_000_000 { findings.append("SVG exceeds 2MB") }
        // Well-formedness via XMLParser.
        if !XMLWellFormedCheck.isWellFormed(svg) { findings.append("not well-formed XML") }
        return ArtifactValidation(isValid: findings.isEmpty, findings: findings)
    }
}

private final class XMLWellFormedCheck: NSObject, XMLParserDelegate {
    static func isWellFormed(_ xml: String) -> Bool {
        guard let data = xml.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = XMLWellFormedCheck()
        parser.delegate = delegate
        return parser.parse()
    }
}
