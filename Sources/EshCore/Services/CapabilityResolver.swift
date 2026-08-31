import Foundation

/// Resolves requested inference options against what the target backend can actually do, producing
/// an honest `CapabilityResolution` (applied/transformed/ignored/rejected) plus any system-prompt
/// augmentation needed to approximate a request. Implements the M8 principle: never silently
/// pretend an unsupported option was honored.
public struct CapabilityResolver: Sendable {
    public init() {}

    public struct Outcome: Sendable {
        public var resolution: CapabilityResolution
        /// A system instruction to inject to approximate the request (e.g. JSON output), or nil.
        public var systemInstructionAugmentation: String?
    }

    public func resolve(responseFormat: EshResponseFormat?, backend: BackendKind) -> Outcome {
        guard let responseFormat else {
            return Outcome(resolution: CapabilityResolution(), systemInstructionAugmentation: nil)
        }

        switch responseFormat.kind {
        case .text:
            return Outcome(
                resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .applied, detail: "text")
                ]),
                systemInstructionAugmentation: nil
            )
        case .json:
            return Outcome(
                resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .transformed,
                        detail: "json enforced via instruction; the \(backend.rawValue) runtime has no native constrained decoding, so output validity is not guaranteed")
                ]),
                systemInstructionAugmentation: "Respond with a single valid JSON object and nothing else. Do not include markdown code fences or any prose."
            )
        case .jsonSchema:
            let schema = responseFormat.schema?.trimmingCharacters(in: .whitespacesAndNewlines)
            let augmentation = "Respond with a single JSON object that strictly conforms to this JSON Schema, and nothing else:\n\(schema ?? "(the requested schema)")"
            return Outcome(
                resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .transformed,
                        detail: "json_schema enforced via instruction; no native constrained decoding, so schema conformance is not guaranteed")
                ]),
                systemInstructionAugmentation: augmentation
            )
        case .grammar:
            return Outcome(
                resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .rejected,
                        detail: "grammar-constrained decoding is not available in the current \(backend.rawValue) runtime")
                ]),
                systemInstructionAugmentation: nil
            )
        }
    }
}
