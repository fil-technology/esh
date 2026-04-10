import Foundation

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
        guard requestedMode == .automatic else {
            return requestedMode
        }

        switch intent {
        case .documentQA, .multimodal:
            return .turbo
        case .code, .agentRun:
            return calibrationLocator.hasCalibration(for: modelID) ? .triattention : .turbo
        case .chat:
            return .raw
        }
    }
}
