import Foundation

public struct ValidatedRoutingToolCall: Hashable, Sendable {
    public var name: String
    public var arguments: [String: String]
    public var resolvedFileURL: URL?
}

public struct RoutingDecisionValidator: Sendable {
    private let workspaceRootURL: URL
    private let minimumConfidence: Double
    private let allowedTools: Set<String> = ["read_file"]

    public init(workspaceRootURL: URL, minimumConfidence: Double = 0.5) {
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.minimumConfidence = minimumConfidence
    }

    public func decodeDecision(from output: String) throws -> RoutingDecision {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = json.data(using: .utf8) else {
            throw StoreError.invalidManifest("Router output was not valid UTF-8.")
        }
        return try JSONCoding.decoder.decode(RoutingDecision.self, from: data)
    }

    public func validateDecision(_ decision: RoutingDecision) throws {
        guard decision.confidence >= minimumConfidence else {
            throw StoreError.invalidManifest("Router confidence \(decision.confidence) is below \(minimumConfidence).")
        }
        if decision.action == .callTool {
            guard decision.toolCall != nil else {
                throw StoreError.invalidManifest("Router selected call_tool without a toolCall.")
            }
        }
        if decision.action != .callTool, decision.toolCall != nil {
            throw StoreError.invalidManifest("Router included a toolCall for \(decision.action.rawValue).")
        }
        if decision.targetModelRole == .router || decision.targetModelRole == .embedding {
            throw StoreError.invalidManifest("Router target role \(decision.targetModelRole.rawValue) cannot produce final answers.")
        }
    }

    public func validateToolCall(_ toolCall: RoutingToolCall) throws -> ValidatedRoutingToolCall {
        guard allowedTools.contains(toolCall.name) else {
            throw StoreError.invalidManifest("Tool \(toolCall.name) is not allowed.")
        }
        switch toolCall.name {
        case "read_file":
            guard let rawPath = toolCall.arguments["path"], rawPath.isEmpty == false else {
                throw StoreError.invalidManifest("read_file requires a non-empty path argument.")
            }
            let candidate = URL(fileURLWithPath: rawPath, relativeTo: workspaceRootURL)
                .standardizedFileURL
            guard candidate.path == workspaceRootURL.path || candidate.path.hasPrefix(workspaceRootURL.path + "/") else {
                throw StoreError.invalidManifest("read_file path must stay inside the workspace.")
            }
            return ValidatedRoutingToolCall(
                name: toolCall.name,
                arguments: toolCall.arguments,
                resolvedFileURL: candidate
            )
        default:
            throw StoreError.invalidManifest("Tool \(toolCall.name) is not implemented.")
        }
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(text[start...end])
    }
}
