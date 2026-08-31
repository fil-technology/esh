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

    public func resolve(responseFormat: EshResponseFormat?, backend: BackendKind, tools: [EshToolDefinition]? = nil) -> Outcome {
        var extraOptions: [ResolvedOption] = []
        // Tools: native model function-calling is not wired into the local runtime yet, so requested
        // tools are honestly reported as rejected (the esh agent layer does tool orchestration
        // separately). This is not silent — the caller sees it in capabilityResolution.
        if let tools, !tools.isEmpty {
            extraOptions.append(ResolvedOption(name: "tools", resolution: .rejected,
                detail: "native tool/function calling is not available on the \(backend.rawValue) runtime yet; use `esh agent` for tool orchestration"))
        }

        guard let responseFormat else {
            return Outcome(resolution: CapabilityResolution(options: extraOptions), systemInstructionAugmentation: nil)
        }

        let base = resolveFormat(responseFormat, backend: backend)
        return Outcome(
            resolution: CapabilityResolution(options: base.resolution.options + extraOptions),
            systemInstructionAugmentation: base.systemInstructionAugmentation
        )
    }

    private func resolveFormat(_ responseFormat: EshResponseFormat, backend: BackendKind) -> Outcome {
        switch responseFormat.kind {
        case .text:
            return Outcome(
                resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .applied, detail: "text")
                ]),
                systemInstructionAugmentation: nil
            )
        case .json:
            // No backend currently has native constrained JSON decoding wired. Strict callers get a
            // rejection rather than a prompt-instruction approximation.
            if responseFormat.strict {
                return Outcome(
                    resolution: CapabilityResolution(options: [
                        ResolvedOption(name: "response_format", resolution: .rejected,
                            detail: "strict json requested but the \(backend.rawValue) runtime has no native constrained decoding; not approximating because strict was set")
                    ]),
                    systemInstructionAugmentation: nil
                )
            }
            return Outcome(
                resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .approximated,
                        detail: "json approximated via a prompt instruction (no native constrained decoding on \(backend.rawValue)); validity is not guaranteed. Set strict to reject approximation.")
                ]),
                systemInstructionAugmentation: "Respond with a single valid JSON object and nothing else. Do not include markdown code fences or any prose."
            )
        case .jsonSchema:
            let schema = responseFormat.schema?.trimmingCharacters(in: .whitespacesAndNewlines)
            if responseFormat.strict {
                return Outcome(
                    resolution: CapabilityResolution(options: [
                        ResolvedOption(name: "response_format", resolution: .rejected,
                            detail: "strict json_schema requested but no native constrained decoding is available on \(backend.rawValue); not approximating because strict was set")
                    ]),
                    systemInstructionAugmentation: nil
                )
            }
            let augmentation = "Respond with a single JSON object that strictly conforms to this JSON Schema, and nothing else:\n\(schema ?? "(the requested schema)")"
            return Outcome(
                resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .approximated,
                        detail: "json_schema approximated via a prompt instruction (no native constrained decoding); conformance is not guaranteed. Set strict to reject approximation.")
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
