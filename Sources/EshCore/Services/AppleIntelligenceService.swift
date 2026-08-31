import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Availability of the Apple Foundation Models (Apple Intelligence) on-device system model.
public enum AppleIntelligenceAvailability: String, Codable, Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedOS          // macOS too old for FoundationModels
    case frameworkUnavailable   // built without the FoundationModels SDK
    case unknown
}

/// Status of the Apple Intelligence provider — a zero-download, on-device intelligence provider
/// esh can offer as a fallback/option. Reported through capabilities/doctor/onboarding.
public struct AppleIntelligenceStatus: Codable, Sendable, Equatable {
    public var available: Bool
    public var availability: AppleIntelligenceAvailability
    public var detail: String
    /// True when execution is strictly on-device. (Private Cloud Compute, if adopted later, is a
    /// distinct semantic and must not be conflated with strictly-local execution.)
    public var onDevice: Bool
    /// Actionable fix when unavailable.
    public var suggestedFix: String?

    public init(available: Bool, availability: AppleIntelligenceAvailability, detail: String, onDevice: Bool, suggestedFix: String? = nil) {
        self.available = available
        self.availability = availability
        self.detail = detail
        self.onDevice = onDevice
        self.suggestedFix = suggestedFix
    }
}

/// Detects Apple Foundation Models availability without requiring any model download. Compiles and
/// runs whether or not the FoundationModels SDK/OS is present (guarded), so esh never hard-depends
/// on Apple Intelligence.
public struct AppleIntelligenceService: Sendable {
    public init() {}

    public func status() -> AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return AppleIntelligenceStatus(
                    available: true, availability: .available,
                    detail: "Apple Intelligence on-device model is available (no download required).",
                    onDevice: true
                )
            case .unavailable(let reason):
                return Self.mapUnavailable(reason)
            @unknown default:
                return AppleIntelligenceStatus(available: false, availability: .unknown,
                    detail: "Apple Intelligence availability could not be determined.", onDevice: true)
            }
        } else {
            return AppleIntelligenceStatus(available: false, availability: .unsupportedOS,
                detail: "Apple Intelligence requires a newer macOS.", onDevice: true,
                suggestedFix: "Update macOS to a version that supports Apple Intelligence.")
        }
        #else
        return AppleIntelligenceStatus(available: false, availability: .frameworkUnavailable,
            detail: "This esh build was compiled without the Apple FoundationModels SDK.", onDevice: true)
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func mapUnavailable(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> AppleIntelligenceStatus {
        switch reason {
        case .deviceNotEligible:
            return AppleIntelligenceStatus(available: false, availability: .deviceNotEligible,
                detail: "This Mac is not eligible for Apple Intelligence.", onDevice: true,
                suggestedFix: "Apple Intelligence requires Apple Silicon with Apple Intelligence support.")
        case .appleIntelligenceNotEnabled:
            return AppleIntelligenceStatus(available: false, availability: .appleIntelligenceNotEnabled,
                detail: "Apple Intelligence is not enabled on this Mac.", onDevice: true,
                suggestedFix: "Enable Apple Intelligence in System Settings › Apple Intelligence & Siri.")
        case .modelNotReady:
            return AppleIntelligenceStatus(available: false, availability: .modelNotReady,
                detail: "The Apple Intelligence model is downloading or not ready yet.", onDevice: true,
                suggestedFix: "Wait for Apple Intelligence to finish preparing, then re-check.")
        @unknown default:
            return AppleIntelligenceStatus(available: false, availability: .unknown,
                detail: "Apple Intelligence is unavailable for an unrecognized reason.", onDevice: true)
        }
    }
    #endif
}
