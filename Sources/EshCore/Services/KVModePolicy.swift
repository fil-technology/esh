import Foundation

public struct KVModeResolution: Codable, Hashable, Sendable {
    public let mode: CacheMode
    public let reason: String

    public init(mode: CacheMode, reason: String) {
        self.mode = mode
        self.reason = reason
    }
}

public struct KVModePolicy: Sendable {
    private let calibrationLocator: TriAttentionCalibrationLocator

    public init(calibrationLocator: TriAttentionCalibrationLocator = .init()) {
        self.calibrationLocator = calibrationLocator
    }

    public func defaultMode() -> CacheMode {
        .automatic
    }

    public func defaultIntent() -> SessionIntent {
        .chat
    }

    public func resolvedMode(
        requestedMode: CacheMode,
        intent: SessionIntent,
        modelID: String
    ) -> CacheMode {
        resolveMode(
            requestedMode: requestedMode,
            intent: intent,
            modelID: modelID,
            contextPackage: nil
        ).mode
    }

    public func resolveMode(
        requestedMode: CacheMode,
        intent: SessionIntent,
        modelID: String,
        contextPackage: ContextPackage?
    ) -> KVModeResolution {
        guard requestedMode == .automatic else {
            return KVModeResolution(mode: requestedMode, reason: "explicit mode requested")
        }

        switch intent {
        case .documentQA, .multimodal:
            return KVModeResolution(mode: .turbo, reason: "retrieval-heavy intent prefers turbo packaging")
        case .code, .agentRun:
            let hasCalibration = calibrationLocator.hasCalibration(for: modelID)
            if let contextPackage,
               contextPackage.manifest.files.count > 6 || contextPackage.brief.rankedResults.count > 4 {
                return KVModeResolution(mode: .turbo, reason: "broader context package prefers turbo reuse")
            }
            if hasCalibration {
                return KVModeResolution(mode: .triattention, reason: "focused code context with calibration prefers triattention")
            }
            return KVModeResolution(mode: .turbo, reason: "code intent without calibration falls back to turbo")
        case .chat:
            return KVModeResolution(mode: .raw, reason: "chat intent defaults to raw cache")
        }
    }
}
