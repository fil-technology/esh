import Foundation

public struct PromptCacheKey: Codable, Hashable, Sendable {
    public static let schemaVersion = "esh.prompt-cache-key.v1"

    public var schemaVersion: String
    public var hash: String
    public var backend: BackendKind
    public var modelID: String
    public var tokenizerID: String?
    public var runtimeVersion: String
    public var toolSignature: String
    public var normalizedMessageCount: Int

    public init(
        schemaVersion: String = PromptCacheKey.schemaVersion,
        hash: String,
        backend: BackendKind,
        modelID: String,
        tokenizerID: String? = nil,
        runtimeVersion: String,
        toolSignature: String,
        normalizedMessageCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.hash = hash
        self.backend = backend
        self.modelID = modelID
        self.tokenizerID = tokenizerID
        self.runtimeVersion = runtimeVersion
        self.toolSignature = toolSignature
        self.normalizedMessageCount = normalizedMessageCount
    }

    static func make(
        backend: BackendKind,
        modelID: String,
        tokenizerID: String?,
        runtimeVersion: String,
        toolSignature: String?,
        messages: [Message]
    ) -> PromptCacheKey {
        let effectiveToolSignature = toolSignature?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "tools:none"
        let payload = PromptCacheKeyPayload(
            schemaVersion: schemaVersion,
            backend: backend,
            modelID: modelID,
            tokenizerID: tokenizerID,
            runtimeVersion: runtimeVersion,
            toolSignature: effectiveToolSignature,
            messages: messages.map { message in
                PromptCacheKeyMessage(role: message.role, text: message.text)
            }
        )
        let data = (try? JSONCoding.encoder.encode(payload)) ?? Data()
        let canonical = String(decoding: data, as: UTF8.self)
        return PromptCacheKey(
            hash: Fingerprint.sha256([canonical]),
            backend: backend,
            modelID: modelID,
            tokenizerID: tokenizerID,
            runtimeVersion: runtimeVersion,
            toolSignature: effectiveToolSignature,
            normalizedMessageCount: messages.count
        )
    }
}

private struct PromptCacheKeyPayload: Codable, Hashable, Sendable {
    var schemaVersion: String
    var backend: BackendKind
    var modelID: String
    var tokenizerID: String?
    var runtimeVersion: String
    var toolSignature: String
    var messages: [PromptCacheKeyMessage]
}

private struct PromptCacheKeyMessage: Codable, Hashable, Sendable {
    var role: Message.Role
    var text: String
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
