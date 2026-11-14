#if os(macOS)
import Foundation
import EshCore
import EshRuntime

// The shipped, VALIDATED model catalog for the compatibility engines that run several concrete models (today:
// the mlx_audio speech engines). Produced — never hand-edited — by `scripts/model-catalog/validate.py`, which
// provisions each candidate, runs a tiny real job through the same bridge command the host runs, checks the
// output, and records what it observed. EshMacCapabilities turns it into `CapabilityModelOption`s on the
// provider descriptor + live per-device readiness, so a consumer only ever offers models esh has actually run.

public struct ValidatedModelCatalog: Codable, Sendable, Hashable {
    /// A Python package a model needs beyond its engine's base requirements (esh-internal: never surfaced as
    /// part of the consumer-facing option, which stays Python-free).
    public struct Package: Codable, Sendable, Hashable {
        public let module: String
        public let pip: String
    }

    public struct AuxiliaryDownload: Codable, Sendable, Hashable {
        public let repo: String
        public let bytes: Int64
    }

    public struct ValidationStamp: Codable, Sendable, Hashable {
        public let date: String
        public let machine: String?
        public let python: String?
        public let mlxAudio: String?
        public let mlx: String?

        /// "mlx-audio 0.6.5, mlx 0.32.4, Python 3.11.14 on Apple M1 Pro, 32 GB"
        public var summary: String {
            var parts: [String] = []
            if let mlxAudio { parts.append("mlx-audio \(mlxAudio)") }
            if let mlx { parts.append("mlx \(mlx)") }
            if let python { parts.append("Python \(python)") }
            let runtime = parts.joined(separator: ", ")
            guard let machine, !machine.isEmpty else { return runtime }
            return runtime.isEmpty ? machine : "\(runtime) on \(machine)"
        }
    }

    /// One validated (or validated-and-rejected) model, exactly as the harness recorded it.
    public struct Entry: Codable, Sendable, Hashable {
        public let id: String
        public let capability: String
        public let engine: String
        public let family: String
        public let displayName: String
        public let rank: Int
        public let isDefault: Bool
        public let status: String
        public let extraPackages: [Package]
        public let requiredArgs: [String: String]
        public let weightBytes: Int64?
        public let firstRunDownloadBytes: Int64?
        public let auxiliaryDownloads: [AuxiliaryDownload]?
        public let peakMemoryBytes: Int64?
        public let recommendedMinMemoryGB: Int?
        public let minChip: String?
        public let license: String?
        public let commercialUse: Bool?
        public let licenseNote: String?
        public let gated: Bool?
        public let sampleOutputOK: Bool
        public let sampleCheck: String?
        public let coldRunSeconds: Double?
        public let warmRunSeconds: Double?
        public let error: String?
        public let missingModule: String?
        public let note: String?
        public let lastValidated: ValidationStamp

        public var validationStatus: CapabilityModelOption.ValidationStatus {
            CapabilityModelOption.ValidationStatus(rawValue: status) ?? .failed
        }

        /// The consumer-facing, Python-free option for this entry.
        public var modelOption: CapabilityModelOption {
            CapabilityModelOption(
                id: id, displayName: displayName, family: family, rank: rank,
                isDefault: isDefault && validationStatus == .ok, status: validationStatus,
                weightBytes: weightBytes, firstRunDownloadBytes: firstRunDownloadBytes,
                peakMemoryBytes: peakMemoryBytes, recommendedMinMemoryGB: recommendedMinMemoryGB,
                defaultOptions: requiredArgs, licenseIdentifier: license, commercialUse: commercialUse,
                licenseNote: licenseNote, note: note,
                validationError: validationStatus == .ok ? nil : (error ?? missingModule.map { "needs Python module '\($0)'" }),
                lastValidated: lastValidated.date, validatedWith: lastValidated.summary)
        }
    }

    public let schemaVersion: Int
    public let updatedAt: String
    public let generatedWith: [String: String]
    public let validatedOn: String?
    public let entries: [Entry]

    public init(schemaVersion: Int = 1, updatedAt: String, generatedWith: [String: String] = [:],
                validatedOn: String? = nil, entries: [Entry]) {
        self.schemaVersion = schemaVersion; self.updatedAt = updatedAt; self.generatedWith = generatedWith
        self.validatedOn = validatedOn; self.entries = entries
    }

    public static func decode(_ data: Data) throws -> ValidatedModelCatalog {
        try JSONDecoder().decode(ValidatedModelCatalog.self, from: data)
    }

    /// The catalog shipped inside the SDK bundle (`Resources/catalog/validated-models.json`). An absent or
    /// unreadable resource yields an EMPTY catalog — honest: esh then offers no validated alternates rather
    /// than guessing.
    public static func bundled() -> ValidatedModelCatalog { _bundled }

    private static let _bundled: ValidatedModelCatalog = {
        guard let url = Bundle.module.url(forResource: "validated-models", withExtension: "json", subdirectory: "catalog")
                ?? Bundle.module.url(forResource: "validated-models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else {
            return ValidatedModelCatalog(updatedAt: "", entries: [])
        }
        return catalog
    }()

    /// Entries for one engine, best-ranked first.
    public func entries(engine: CompatibilityEngineID) -> [Entry] {
        entries.filter { $0.engine == engine.rawValue }.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
    }

    /// Entries for one capability, best-ranked first.
    public func entries(capability: CapabilityID) -> [Entry] {
        entries.filter { $0.capability == capability.rawValue }.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
    }

    public func entry(id: String, engine: CompatibilityEngineID) -> Entry? {
        entries.first { $0.id == id && $0.engine == engine.rawValue }
    }

    /// esh's default model for an engine: the validated-ok entry flagged default, else the best-ranked ok one.
    public func defaultEntry(engine: CompatibilityEngineID) -> Entry? {
        let ok = entries(engine: engine).filter { $0.validationStatus == .ok }
        return ok.first { $0.isDefault } ?? ok.first
    }

    /// Consumer-facing options for an engine (every recorded entry, so a UI can also show what was REJECTED and
    /// why; only `isRunnable` ones should be selectable).
    public func modelOptions(engine: CompatibilityEngineID) -> [CapabilityModelOption] {
        entries(engine: engine).map(\.modelOption)
    }
}

// MARK: - Live per-model readiness

extension CompatibilityEngineState {
    /// Default per-model readiness derived from the engine-wide state (used by hosts that can't inspect
    /// individual models, e.g. test mocks).
    var modelReadiness: ModelOptionReadiness {
        switch self {
        case .ready:                         return .ready
        case .notInstalled:                  return .needsSetup(reason: "esh installs the engine runtime on first use")
        case .requiresDownload:              return .needsSetup(reason: "esh installs the engine runtime on first use")
        case .installing(let p):             return .needsSetup(reason: String(format: "installing (%.0f%%)", p * 100))
        case .repairRequired(let r):         return .needsSetup(reason: r)
        case .failed(let r):                 return .needsSetup(reason: r)
        case .unsupportedOnPlatform:         return .unsupportedOnPlatform
        case .insufficientResources(let r):  return .unsupportedOnThisMachine(reason: r)
        }
    }
}

enum ModelOptionNotes {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func fitPhrase(_ fit: ModelOptionFit) -> String? {
        switch fit {
        case .comfortable: return "fits comfortably"
        case .tight: return "tight fit on this Mac"
        case .exceeds: return "too large for this Mac"
        case .unknown: return nil
        }
    }

    /// One honest line for the pill.
    static func note(readiness: ModelOptionReadiness, fit: ModelOptionFit, option: CapabilityModelOption) -> String {
        var parts: [String] = []
        switch readiness {
        case .ready: parts.append("Ready")
        case .needsSetup(let r): parts.append("Setup needed: \(r)")
        case .downloadRequired(let b): parts.append(b.map { "Download \(bytes($0))" } ?? "Download required")
        case .unsupportedOnThisMachine(let r): return r
        case .notValidated(let r): return r
        case .unsupportedOnPlatform: return "Not available on this platform"
        }
        if let f = fitPhrase(fit) { parts.append(f) }
        if option.commercialUse == false { parts.append("non-commercial license") }
        return parts.joined(separator: " · ")
    }

    static func notValidatedReason(_ option: CapabilityModelOption) -> String {
        let what: String
        switch option.status {
        case .ok: what = "Validated"
        case .needsDeps: what = "Not offered: needs extra dependencies"
        case .failed: what = "Not offered: failed esh validation"
        case .unsupported: what = "Not offered: unsupported by the runtime"
        }
        if let date = option.lastValidated, !date.isEmpty { return "\(what) (\(date))" }
        return what
    }
}

#endif
