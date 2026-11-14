import Foundation

// esh 2.4 — validated per-model options for a capability provider. A provider that can run several concrete
// models (e.g. the mlx_audio TTS engine: Kokoro / CSM / Dia / Bark) advertises the ones esh has ACTUALLY
// validated — provisioned, loaded and run on a real tiny job by `scripts/model-catalog/validate.py` — with the
// facts that run observed. A consumer renders these as the model pill; it never lists repos esh hasn't run.
//
// Two layers:
//  - `CapabilityModelOption` — STATIC, shipped, Codable facts (sizes, peak memory, license, known-good args,
//    validation status/date). Lives on `CapabilityProviderDescriptor.modelOptions`.
//  - `ModelOptionAvailability` — LIVE, per-device state computed on demand (ready / needs setup / download
//    required + size / unsupported on this machine) plus a fit judgment and a one-line note, from
//    `EshRuntime.modelOptions(for:)`.

/// One validated model a provider can run, as recorded by esh's validation harness.
public struct CapabilityModelOption: Codable, Hashable, Sendable, Identifiable {
    /// Outcome of the most recent validation run.
    public enum ValidationStatus: String, Codable, Hashable, Sendable {
        /// Provisioned, loaded, ran a real job, and the output passed its check.
        case ok
        /// Runs only with extra Python packages esh could not install/resolve during validation.
        case needsDeps = "needs-deps"
        /// Loaded/ran but failed (crash, empty/garbled output). Not offered as runnable.
        case failed
        /// The runtime does not support this model (architecture not implemented).
        case unsupported
    }

    /// The model id the provider accepts — a Hugging Face repo id. Pass it as `ExecutionRequest.options["model"]`.
    public var id: String
    public var displayName: String
    /// Model family (e.g. `kokoro`, `whisper`) — group/sort key, never a behavior switch for the consumer.
    public var family: String
    /// Rank within the capability (1 = esh's recommended default).
    public var rank: Int
    /// esh's default model for this provider when the caller doesn't choose one.
    public var isDefault: Bool
    public var status: ValidationStatus
    /// Total repository size on Hugging Face.
    public var weightBytes: Int64?
    /// What the first run actually downloaded (primary repo + any auxiliary repos the runtime fetched).
    public var firstRunDownloadBytes: Int64?
    /// Peak memory footprint observed for the validation job (the process' unified-memory high-water mark).
    public var peakMemoryBytes: Int64?
    /// esh's recommendation for the smallest Mac memory tier that runs it comfortably (peak + OS/app headroom).
    public var recommendedMinMemoryGB: Int?
    /// Known-good values esh applies for knobs the model REQUIRES (e.g. Kokoro's `voice`) when the caller
    /// leaves them unset. A consumer may surface these as defaults; it never has to supply them.
    public var defaultOptions: [String: String]
    /// SPDX-style license id of the weights, as declared by the model card (or upstream when the card is silent).
    public var licenseIdentifier: String?
    /// Whether commercial use is permitted (`nil` = unknown — treat as not cleared).
    public var commercialUse: Bool?
    /// Human-readable license caveat (attribution, runtime GPL dependencies, …).
    public var licenseNote: String?
    /// Usage note (e.g. "prefix speaker turns with [S1]/[S2]").
    public var note: String?
    /// Why validation failed, when `status != .ok`.
    public var validationError: String?
    /// ISO date (yyyy-MM-dd) of the last validation run.
    public var lastValidated: String?
    /// Runtime the validation ran on (e.g. "mlx-audio 0.6.5, mlx 0.32.4, Python 3.11.14 on Apple M1 Pro, 32 GB").
    public var validatedWith: String?

    public init(id: String, displayName: String, family: String, rank: Int, isDefault: Bool,
                status: ValidationStatus, weightBytes: Int64? = nil, firstRunDownloadBytes: Int64? = nil,
                peakMemoryBytes: Int64? = nil, recommendedMinMemoryGB: Int? = nil,
                defaultOptions: [String: String] = [:],
                licenseIdentifier: String? = nil, commercialUse: Bool? = nil, licenseNote: String? = nil,
                note: String? = nil, validationError: String? = nil, lastValidated: String? = nil,
                validatedWith: String? = nil) {
        self.id = id; self.displayName = displayName; self.family = family; self.rank = rank
        self.isDefault = isDefault; self.status = status; self.weightBytes = weightBytes
        self.firstRunDownloadBytes = firstRunDownloadBytes; self.peakMemoryBytes = peakMemoryBytes
        self.recommendedMinMemoryGB = recommendedMinMemoryGB; self.defaultOptions = defaultOptions
        self.licenseIdentifier = licenseIdentifier
        self.commercialUse = commercialUse; self.licenseNote = licenseNote; self.note = note
        self.validationError = validationError; self.lastValidated = lastValidated
        self.validatedWith = validatedWith
    }

    /// Only validated-ok models are offered as runnable choices.
    public var isRunnable: Bool { status == .ok }
}

/// Live, per-device readiness of one model option.
public enum ModelOptionReadiness: Sendable, Equatable {
    /// Runtime + packages present and the weights are on disk — runs now, offline.
    case ready
    /// The engine runtime or a model-specific package is missing; esh installs it on first use / repair.
    case needsSetup(reason: String)
    /// Runtime ready; the weights still need downloading (`bytes` when known).
    case downloadRequired(bytes: Int64?)
    /// This Mac can't run it (too little memory for the observed peak, or not Apple silicon / wrong OS).
    case unsupportedOnThisMachine(reason: String)
    /// esh validated it and it did NOT pass (`failed` / `unsupported` / `needs-deps`) — not offered.
    case notValidated(reason: String)
    /// The whole platform can't run the engine (e.g. iOS for a Python compat engine).
    case unsupportedOnPlatform
}

/// How the observed peak memory compares to this Mac's physical memory.
public enum ModelOptionFit: String, Sendable, Equatable, Codable {
    /// Peak + headroom fits comfortably.
    case comfortable
    /// Fits, but with little headroom — expect pressure alongside other apps/models.
    case tight
    /// Peak exceeds what this Mac can safely provide.
    case exceeds
    /// No measurement recorded.
    case unknown
}

/// One row of a model pill: the static facts + live state, already reduced to what a UI shows.
public struct ModelOptionAvailability: Sendable, Equatable, Identifiable {
    public var option: CapabilityModelOption
    /// The provider that runs it (pin with `request.model = providerID`, choose with `options["model"] = option.id`).
    public var providerID: String
    public var readiness: ModelOptionReadiness
    public var fit: ModelOptionFit
    /// The size that matters right now: bytes still to download, else the on-disk weight size.
    public var sizeBytes: Int64?
    /// One honest line for the pill (e.g. "Download 312 MB · fits comfortably").
    public var note: String

    public var id: String { providerID + "/" + option.id }

    public init(option: CapabilityModelOption, providerID: String, readiness: ModelOptionReadiness,
                fit: ModelOptionFit, sizeBytes: Int64?, note: String) {
        self.option = option; self.providerID = providerID; self.readiness = readiness
        self.fit = fit; self.sizeBytes = sizeBytes; self.note = note
    }

    /// Pure fit judgment (unit-testable): peak + 4 GiB OS/app headroom vs physical memory.
    public static func fit(peakMemoryBytes: Int64?, physicalMemoryBytes: Int64) -> ModelOptionFit {
        guard let peak = peakMemoryBytes, peak > 0, physicalMemoryBytes > 0 else { return .unknown }
        let headroom: Int64 = 4 * 1_073_741_824
        if peak + headroom > physicalMemoryBytes { return .exceeds }
        // Comfortable when the job leaves at least half of RAM for everything else.
        return (peak + headroom) * 2 <= physicalMemoryBytes ? .comfortable : .tight
    }
}

/// A provider that runs several concrete, validated models can conform so `EshRuntime.modelOptions(for:)` can
/// list them with live readiness.
public protocol ModelOptionReporting: Sendable {
    func modelOptionAvailability(for capability: CapabilityID) async -> [ModelOptionAvailability]
}
