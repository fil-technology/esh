import Foundation

// esh 2.1 — Tier 0 deterministic router (spec 86eyucfbu §3). Handles high-certainty modality + intent
// combinations WITHOUT an LLM, from a data-driven catalog (not a giant regex tree). Conservative by design:
// it emits executeCapability only on a single high-signal match; anything ambiguous or multi-step becomes
// clarify, because a false execution (running the wrong transformation) is far more costly than a question.

/// One data-driven route: a capability, the input modalities it needs present, and high-signal phrases.
public struct CapabilityRoute: Sendable {
    public let capability: CapabilityID
    public let requiredInputs: [ModelModality]     // all must be present (empty = no attachment required)
    public let phrases: [String]                   // lowercased; single words match on word boundaries
    public let extractArguments: (@Sendable (String) -> [String: JSONValue])?
    public init(_ capability: CapabilityID, requires requiredInputs: [ModelModality], phrases: [String],
                extractArguments: (@Sendable (String) -> [String: JSONValue])? = nil) {
        self.capability = capability
        self.requiredInputs = requiredInputs
        self.phrases = phrases
        self.extractArguments = extractArguments
    }
}

public enum CapabilityRouteCatalog {
    /// Extract an upscale factor from phrasings like "2x", "2×", "twice", "double", "4x".
    static func upscaleArgs(_ text: String) -> [String: JSONValue] {
        if let m = text.range(of: #"(\d+)\s*[x×]"#, options: .regularExpression),
           let n = Int(text[m].prefix { $0.isNumber }) , (2...8).contains(n) { return ["scale": .int(n)] }
        if text.contains("twice") || text.contains("double") { return ["scale": .int(2)] }
        if text.contains("quadruple") { return ["scale": .int(4)] }
        return [:]
    }

    public static let routes: [CapabilityRoute] = [
        CapabilityRoute(.imageUpscale, requires: [.image],
            phrases: ["upscale", "up-scale", "super resolution", "super-resolution", "make it bigger",
                      "make this bigger", "twice the size", "double the size", "increase the resolution",
                      "higher resolution", "enlarge", "2x", "4x", "2×", "4×"],
            extractArguments: upscaleArgs),
        CapabilityRoute(.imageSegment, requires: [.image],
            phrases: ["remove background", "remove the background", "cut out background",
                      "cut out the background", "transparent background", "background removal", "remove bg"]),
        CapabilityRoute(.imageOCR, requires: [.image],
            phrases: ["what does it say", "what does this say", "what does this screenshot say",
                      "read the text", "extract text", "ocr", "what's written", "what is written",
                      "read this text", "text in this"]),
        CapabilityRoute(.imageUnderstand, requires: [.image],
            phrases: ["what is in", "what's in", "describe this", "what is this", "what do you see",
                      "explain this image", "caption this", "what's happening in"]),
        // image.generate / vector.generate are detected by verb+visual-noun (see generationCapability),
        // not flat phrases, so "generate a watercolor fox" routes but "generate a poem" stays chat.
        CapabilityRoute(.audioTranscribe, requires: [.audio],
            phrases: ["transcribe", "transcription", "subtitles", "what is said", "what was said"]),
        CapabilityRoute(.audioDiarize, requires: [.audio],
            phrases: ["who spoke", "who said what", "separate speakers", "separate the speakers",
                      "diarize", "speaker labels", "which speaker", "label the speakers"]),
        CapabilityRoute(.videoUnderstand, requires: [.video],
            phrases: ["what happens", "summarize this video", "describe the video", "what is in this video",
                      "what occurs", "what happens in"]),
    ]

    /// Phrases that signal a request esh's agent layer (Ashex) owns, not a capability — kept as an
    /// explicit boundary so we say "unavailable here" rather than mis-route.
    public static let agentBoundaryPhrases = ["deploy", "open the browser", "browse to", "autonomous loop",
        "click the", "fill the form", "scrape ", "run a loop", "control the browser"]

    /// Ambiguous "improve" phrasings that must clarify (upscale? denoise? segment?) rather than guess.
    public static let ambiguousImagePhrases = ["improve", "make better", "make it better", "make this better",
        "enhance", "fix this", "fix the image", "make clearer", "make it clearer", "clean up", "touch up",
        "better quality", "make nicer"]

    static let genVerbs = ["generate", "create", "draw", "paint", "render", "design", "make me", "give me"]
    static let visualNouns = ["image", "picture", "illustration", "photo", "photograph", "drawing", "painting",
        "portrait", "landscape", "wallpaper", "poster", "artwork", "watercolor", "photorealistic", "sketch",
        "cartoon", "anime", "render of", "3d model"]
    static let svgNouns = ["logo", "icon", "vector", "svg", "diagram", "vector graphic"]

    /// Detect a generation request from a verb + visual-noun. Returns vector.generate when SVG/vector is
    /// explicit, else image.generate — or nil when it's not a visual generation ask ("generate a poem").
    static func generationCapability(_ text: String) -> CapabilityID? {
        let hasGenVerb = genVerbs.contains { text.contains($0) }
        guard hasGenVerb else { return nil }
        let wantsSVG = text.contains("svg") || text.contains("vector")
        if wantsSVG, svgNouns.contains(where: { text.contains($0) }) { return .vectorGenerate }
        if visualNouns.contains(where: { text.contains($0) }) { return .imageGenerate }
        // "logo/icon" without svg/vector is still typically a vector ask.
        if text.contains("logo") || text.contains("icon") { return .vectorGenerate }
        return nil
    }
}

public struct DeterministicIntentRouter: Sendable {
    private let routes: [CapabilityRoute]
    public init(routes: [CapabilityRoute] = CapabilityRouteCatalog.routes) { self.routes = routes }

    private static let provenance = RouterProvenance(tier: "tier0-deterministic", router: "rules")

    /// Route a message + the modalities of its typed inputs into a CapabilityIntent. `inputModalities` is
    /// derived from the request's attachments (image/audio/video/…); order matters for inputRefs.
    public func route(message: String, inputModalities: [ModelModality]) -> CapabilityIntent {
        let text = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let present = Set(inputModalities)
        let prov = Self.provenance

        // Agent-layer boundary first — don't mis-route deploy/browser/loop asks into a capability.
        if CapabilityRouteCatalog.agentBoundaryPhrases.contains(where: { text.contains($0) }) {
            return CapabilityIntent(action: .unsupported, reason: "This looks like an agent/automation task, which esh's capability runtime doesn't perform here.", provenance: prov)
        }

        // Collect matching routes whose required inputs are all present.
        var matches: [(route: CapabilityRoute, refs: [String])] = []
        for route in routes {
            guard route.requiredInputs.allSatisfy({ present.contains($0) }) else { continue }
            guard route.phrases.contains(where: { Self.matches(text, phrase: $0) }) else { continue }
            matches.append((route, Self.inputRefs(for: route, inputModalities: inputModalities)))
        }
        // Generation (text → image/svg) is verb+visual-noun detected, not phrase-listed.
        if let genCap = CapabilityRouteCatalog.generationCapability(text) {
            matches.append((CapabilityRoute(genCap, requires: [], phrases: []), []))
        }
        // Distinct capabilities matched.
        let distinct = Array(Set(matches.map { $0.route.capability }))

        // Ambiguous "improve/enhance/fix" with an image and no specific op → clarify (never guess).
        let isAmbiguousImage = present.contains(.image)
            && CapabilityRouteCatalog.ambiguousImagePhrases.contains(where: { text.contains($0) })

        if distinct.count >= 2 {
            // Explicit multi-step ("remove background and upscale"): propose an ordered plan but CLARIFY to
            // confirm rather than auto-run a pipeline from Tier 0.
            let ordered = Self.orderedPlan(matches.map { $0.route.capability })
            let steps = ordered.compactMap { cap in matches.first(where: { $0.route.capability == cap }) }
                .map { m in CapabilityIntent(action: .executeCapability, capability: m.route.capability, inputRefs: m.refs,
                                             arguments: m.route.extractArguments?(text) ?? [:], provenance: prov) }
            return CapabilityIntent(action: .clarify, alternatives: ordered,
                reason: "This looks like \(ordered.count) steps (\(ordered.map { $0.rawValue }.joined(separator: " → "))). Run them in this order?",
                provenance: prov, plan: steps)
        }

        if let only = matches.first, distinct.count == 1, !isAmbiguousImage {
            let args = only.route.extractArguments?(text) ?? [:]
            return CapabilityIntent(action: .executeCapability, capability: only.route.capability,
                                    inputRefs: only.refs, arguments: args, provenance: prov)
        }

        if isAmbiguousImage {
            return CapabilityIntent(action: .clarify,
                alternatives: [.imageUpscale, .imageSegment, .imageUnderstand],
                reason: "Did you want to upscale it, remove the background, or something else?", provenance: prov)
        }

        // Wrong-modality: a capability's phrases match but its required input modality is absent (e.g.
        // "who spoke when?" or "transcribe this" with an IMAGE attached). Clarify — never route to a
        // different capability just because a question mark triggers the understand fallback.
        let wrongModality = routes.contains { r in
            !r.requiredInputs.isEmpty && !r.requiredInputs.allSatisfy { present.contains($0) }
                && r.phrases.contains { Self.matches(text, phrase: $0) }
        }
        if wrongModality {
            return CapabilityIntent(action: .clarify,
                reason: "This looks like a different kind of request than the attached \(Self.describe(present)). What would you like to do?",
                provenance: prov)
        }

        // Tier-0's rules are English. For predominantly non-Latin text (Cyrillic/Hebrew/…) it must NOT guess
        // a capability from the generic question→understand fallback (that mis-routes e.g. a Russian "what's
        // written here?" to understand instead of OCR). Defer to Tier-1 by clarifying (attachment) / chatting.
        let nonLatin = Self.isMostlyNonLatin(text)

        // A bare question about an attached image/video → understand (before the no-verb clarify).
        if !nonLatin, present.contains(.video), Self.looksLikeAQuestionAboutInput(text, present: present) {
            return CapabilityIntent(action: .executeCapability, capability: .videoUnderstand,
                                    inputRefs: ["attachment_\(inputModalities.firstIndex(of: .video) ?? 0)"], provenance: prov)
        }
        if !nonLatin, present.contains(.image), Self.looksLikeAQuestionAboutInput(text, present: present) {
            // A "what does it say / what's written / read" question is an OCR intent; other questions → understand.
            let ocrWords = ["say", "says", "written", "read", "text", "label", "caption"]
            let cap: CapabilityID = ocrWords.contains(where: { Self.matches(text, phrase: $0) }) ? .imageOCR : .imageUnderstand
            return CapabilityIntent(action: .executeCapability, capability: cap,
                                    inputRefs: ["attachment_\(inputModalities.firstIndex(of: .image) ?? 0)"], provenance: prov)
        }
        // An attachment with no actionable verb and no (parseable) question → clarify.
        if present.contains(.image) || present.contains(.audio) || present.contains(.video) {
            return CapabilityIntent(action: .clarify,
                reason: "What would you like me to do with this \(Self.describe(present))?", provenance: prov)
        }

        // Otherwise ordinary conversation — the default, so ordinary chat stays ordinary (spec §12).
        return .chat(prov)
    }

    // MARK: - Helpers

    /// Word-boundary match for single tokens (so "scale" ≠ "scalar"); substring for multiword phrases.
    static func matches(_ text: String, phrase: String) -> Bool {
        if phrase.contains(" ") || phrase.contains("-") || phrase.contains("×") { return text.contains(phrase) }
        // token match
        let tokens = text.split { !$0.isLetter && !$0.isNumber && $0 != "×" }.map(String.init)
        return tokens.contains(phrase)
    }

    static func inputRefs(for route: CapabilityRoute, inputModalities: [ModelModality]) -> [String] {
        // Reference the first input of each required modality (attachment_<index>).
        var refs: [String] = []
        for need in route.requiredInputs {
            if let idx = inputModalities.firstIndex(of: need) { refs.append("attachment_\(idx)") }
        }
        return refs
    }

    /// Deterministic safe ordering for known pipelines (segment before upscale; transcribe before diarize).
    static func orderedPlan(_ caps: [CapabilityID]) -> [CapabilityID] {
        let priority: [CapabilityID: Int] = [.imageSegment: 0, .imageUpscale: 1, .audioTranscribe: 0, .audioDiarize: 1]
        return Array(Set(caps)).sorted { (priority[$0] ?? 50) < (priority[$1] ?? 50) }
    }

    static func looksLikeAQuestionAboutInput(_ text: String, present: Set<ModelModality>) -> Bool {
        guard !text.isEmpty else { return false }
        if text.hasSuffix("?") { return true }
        let starters = ["what", "who", "where", "when", "why", "how", "describe", "explain", "summarize", "tell me"]
        return starters.contains { text.hasPrefix($0) }
    }

    /// True when the message is predominantly non-Latin script (Cyrillic/Hebrew/Arabic/CJK) — Tier-0's
    /// English rules can't parse it, so it defers to Tier-1 rather than guessing.
    static func isMostlyNonLatin(_ text: String) -> Bool {
        var latin = 0, other = 0
        for s in text.unicodeScalars {
            let v = s.value
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { latin += 1 }
            else if (0x0400...0x04FF).contains(v) || (0x0590...0x05FF).contains(v) || (0x0600...0x06FF).contains(v)
                || (0x3040...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v) { other += 1 }
        }
        return other > latin && other > 0
    }

    static func describe(_ present: Set<ModelModality>) -> String {
        if present.contains(.image) { return "image" }
        if present.contains(.audio) { return "audio" }
        if present.contains(.video) { return "video" }
        return "file"
    }
}
