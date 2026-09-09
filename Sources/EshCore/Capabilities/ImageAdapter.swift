import Foundation

// esh 2.1 — generic LoRA / adapter support for image-edit models. An adapter is representable INDEPENDENTLY
// of the base model: it declares the base family it applies to, its upstream source (provenance only), the
// local weight file, a default strength and license. This is deliberately NOT special-cased to one style —
// the initial catalog entry (a generic 3D-animation style) is only the first validation adapter for the
// generic path. Adapters install separately from the base and never duplicate base weights.
//
// Naming policy: the user-facing id/label is neutral (e.g. "3d-animation"). Any upstream trademark/style
// marketing name is retained ONLY as diagnostic provenance (`upstreamName`), never surfaced as a product
// style, preset, command, or catalog label. Callers may supply their own user-facing labels.

public struct ImageAdapter: Sendable, Equatable {
    public let id: String                 // neutral user-facing id, e.g. "3d-animation"
    public let displayName: String        // neutral label, e.g. "3D animation style"
    public let backend: ImageEditBackend  // the base family this adapter applies to
    public let baseModelRepo: String?     // recommended base weights (mflux --model), e.g. a pre-quantized repo
    public let baseModelArch: String?     // mflux --base-model architecture for a 3rd-party/pre-quantized repo
    public let sourceRepo: String         // upstream HF repo the adapter installs from
    public let file: String               // adapter weight filename (.safetensors)
    public let defaultScale: Double       // default LoRA strength
    public let license: String
    public let approxSizeMB: Int
    public let upstreamName: String       // provenance/diagnostics ONLY — never a product style label

    public init(id: String, displayName: String, backend: ImageEditBackend, baseModelRepo: String?,
                baseModelArch: String?, sourceRepo: String, file: String, defaultScale: Double = 1.0,
                license: String, approxSizeMB: Int, upstreamName: String) {
        self.id = id; self.displayName = displayName; self.backend = backend
        self.baseModelRepo = baseModelRepo; self.baseModelArch = baseModelArch
        self.sourceRepo = sourceRepo; self.file = file; self.defaultScale = defaultScale
        self.license = license; self.approxSizeMB = approxSizeMB; self.upstreamName = upstreamName
    }

    /// HuggingFace cache directory name for the adapter's source repo (`models--owner--name`).
    public var cacheDirName: String { "models--" + sourceRepo.replacingOccurrences(of: "/", with: "--") }

    /// True if `backend`/`baseModel` are compatible with this adapter (a LoRA only attaches to its own base
    /// family — e.g. a Qwen-Image-Edit LoRA cannot apply to a FLUX base).
    public func isCompatible(backend: ImageEditBackend) -> Bool { backend == self.backend }
}

public enum ImageAdapterCatalog {
    /// Installed-capable adapters keyed by neutral id. The initial entry is the first validation adapter for
    /// the generic LoRA path: a 3D-animation style for Qwen-Image-Edit-2511 (Apache-2.0). Adding a new style
    /// is a data entry here — no code change to the provider/bridge.
    public static let adapters: [String: ImageAdapter] = [
        // DEFAULT 3D style — VALIDATED on 32 GB, Apache-2.0 (commercial-safe): FLUX.2 Klein 4B (esh's default
        // edit backend, ~5 GB peak) + a 3D-animation LoRA. Runs end-to-end on a 32 GB Mac.
        "3d-animation": ImageAdapter(
            id: "3d-animation", displayName: "3D animation style",
            backend: .flux2Klein,
            baseModelRepo: nil, baseModelArch: nil,   // use the flux2-klein backend's default weights
            sourceRepo: "Latentiq/Flux2_Klein_4B_3D2AI_LoRA",
            file: "Flux_Klein_4B_3D2AI_BF16_R16.safetensors", defaultScale: 1.0,
            license: "apache-2.0", approxSizeMB: 46,
            upstreamName: "Flux2_Klein_4B_3D2AI_LoRA"),
        // HIGH-FIDELITY opt-in — SUPPORTED but NOT validated on 32 GB: Qwen-Image-Edit-2511 + its 3D LoRA.
        // The Qwen VL text encoder anchors the model at ~25-27 GB, so base+LoRA needs a >32 GB Mac (or CI).
        // See docs/2_1_QWEN_IMAGE_EDIT_LORA_STATUS.md. Both are Apache-2.0.
        "3d-animation-max": ImageAdapter(
            id: "3d-animation-max", displayName: "3D animation style (high fidelity — needs >32 GB)",
            backend: .qwenEdit,
            baseModelRepo: "mflux-community/qwen-image-edit-2511-mflux-q4",
            baseModelArch: "qwen-image",
            sourceRepo: "prithivMLmods/Qwen-Image-Edit-2511-Pixar-Inspired-3D",
            file: "PI3_20.safetensors", defaultScale: 1.0,
            license: "apache-2.0", approxSizeMB: 236,
            upstreamName: "Qwen-Image-Edit-2511-Pixar-Inspired-3D")
    ]

    /// Neutral aliases → canonical adapter id.
    public static let aliases: [String: String] = ["animated-3d": "3d-animation", "studio-3d": "3d-animation"]

    public static func resolve(_ id: String) -> ImageAdapter? { adapters[aliases[id] ?? id] }

    /// All installable adapter ids (for discovery / `esh image adapters`).
    public static var ids: [String] { adapters.keys.sorted() }

    /// Local path to the installed adapter weights under the image-models HF cache, or nil if not installed.
    /// `hfCacheRoot` is the provider's image-models cache dir (the bridge appends `hub/` under it).
    public static func localWeightsPath(_ adapter: ImageAdapter, hfCacheRoot: String) -> String? {
        let snapshots = URL(fileURLWithPath: hfCacheRoot)
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent(adapter.cacheDirName, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        let fm = FileManager.default
        guard let revs = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        for rev in revs {
            let candidate = rev.appendingPathComponent(adapter.file)
            if fm.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    public static func isInstalled(_ adapter: ImageAdapter, hfCacheRoot: String) -> Bool {
        localWeightsPath(adapter, hfCacheRoot: hfCacheRoot) != nil
    }

    /// Resolved pieces of an edit request contributed by a chosen adapter — shared by the provider and CLI so
    /// adapter → backend/LoRA/base resolution stays in ONE place.
    public struct Resolved: Sendable {
        public var backend: ImageEditBackend
        public var loraPaths: [String]
        public var loraScales: [Double]
        public var model: String?
        public var baseModel: String?
        public var adapterID: String
    }

    /// Resolve a requested adapter id (or alias) for an edit: verifies it exists, is compatible with any
    /// explicitly-pinned backend, and is installed; returns the backend + local LoRA path + base binding.
    /// Throws a typed CapabilityError (unknown / incompatible / not-installed) — the same messages the
    /// provider and CLI both surface.
    public static func resolveForEdit(id requested: String, scale: Double?, pinnedBackend: ImageEditBackend?,
                                      hfCacheRoot: String) throws -> Resolved {
        guard let adapter = resolve(requested) else {
            throw CapabilityError.failed("unknown image adapter '\(requested)' (available: \(ids.joined(separator: ", ")))")
        }
        if let pinned = pinnedBackend, !adapter.isCompatible(backend: pinned) {
            throw CapabilityError.failed("adapter '\(adapter.id)' is not compatible with backend '\(pinned.rawValue)' (needs '\(adapter.backend.rawValue)')")
        }
        guard let path = localWeightsPath(adapter, hfCacheRoot: hfCacheRoot) else {
            throw CapabilityError.failed("adapter '\(adapter.id)' is not installed — install it from \(adapter.sourceRepo) (~\(adapter.approxSizeMB) MB) before use")
        }
        return Resolved(backend: adapter.backend, loraPaths: [path],
                        loraScales: [scale ?? adapter.defaultScale],
                        model: adapter.baseModelRepo, baseModel: adapter.baseModelArch, adapterID: adapter.id)
    }
}

/// Model-Fit inputs for the image-edit backends, so the Scheduler/install-card can expose HONEST hardware
/// viability (Qwen-Image-Edit-2511 is far heavier than the 32 GB default FLUX.2 Klein). Weight figures are
/// on-disk footprints of the pre-quantized mflux snapshots; the Qwen VL text encoder stays ~15.5 GB full
/// precision in every quant, which is why the whole model does not comfortably fit a 32 GB Mac.
public enum ImageEditModelFit {
    public static func input(for backend: ImageEditBackend, width: Int, height: Int,
                             diskRequiredBytes: Int64? = nil) -> ImageModelFitService.Input {
        switch backend {
        case .flux2Klein:
            // Loads full weights and quantizes to 4-bit at load → ~5 GB resident peak. Comfortable on 32 GB.
            return .init(weightsGB: 5.2, runtimeOverheadGB: 1.0, width: width, height: height,
                         diskRequiredBytes: diskRequiredBytes)
        case .qwenEdit:
            // Pre-quantized q4 snapshot ~27 GB on disk; the 15.5 GB fp Qwen2.5-VL text encoder dominates the
            // load transient and resident footprint → does NOT fit 32 GB (measured: RAM guard halts the load).
            return .init(weightsGB: 25.0, runtimeOverheadGB: 2.0, width: width, height: height,
                         diskRequiredBytes: diskRequiredBytes)
        case .kontext:
            return .init(weightsGB: 9.2, runtimeOverheadGB: 1.0, width: width, height: height,
                         diskRequiredBytes: diskRequiredBytes)
        }
    }
}

// Per-backend product metadata for image.edit (label + license), so discovery/UX can show honest badges
// without hard-coding strings in the client.
public extension ImageEditBackend {
    var displayName: String {
        switch self {
        case .flux2Klein: return "FLUX.2 Klein 4B"
        case .kontext:    return "FLUX.1 Kontext [dev]"
        case .qwenEdit:   return "Qwen-Image-Edit-2511"
        }
    }
    var license: String {
        switch self {
        case .flux2Klein, .qwenEdit: return "apache-2.0"
        case .kontext: return "flux-1-dev-non-commercial"
        }
    }
    var commercial: Bool { self != .kontext }
    var isDefault: Bool { self == .flux2Klein }
}

/// Discovery payload for `GET /v1/capability/image-edit/options` — the backends (edit models) and installed
/// style adapters, each with the honest per-Mac fit + license the web UI needs for its pickers/badges.
public struct ImageEditOptionsResponse: Codable, Sendable {
    public var capability: String
    public var backends: [Backend]
    public var adapters: [Adapter]

    public struct Backend: Codable, Sendable {
        public var id: String, label: String, capability: String, license: String
        public var commercial: Bool, fit: String
        public var estimatedPeakGB: Double?
        public var isDefault: Bool
    }
    public struct Adapter: Codable, Sendable {
        public var id: String, label: String, backend: String, license: String
        public var approxSizeMB: Int
        public var installed: Bool
    }

    public static func build(root: PersistenceRoot, host: HostMachineProfile) -> ImageEditOptionsResponse {
        let hfCache = root.cachesURL.appendingPathComponent("image-models", isDirectory: true).path
        let fitSvc = ImageModelFitService()
        let backends = ImageEditBackend.allCases.map { b -> Backend in
            let fit = fitSvc.assess(input: ImageEditModelFit.input(for: b, width: 1024, height: 1024), host: host, root: root)
            return Backend(id: b.rawValue, label: b.displayName, capability: "edit", license: b.license,
                           commercial: b.commercial, fit: fit.fitClass.rawValue,
                           estimatedPeakGB: fit.estimatedPeakMemoryGB, isDefault: b.isDefault)
        }
        let adapters = ImageAdapterCatalog.ids.compactMap { id -> Adapter? in
            guard let a = ImageAdapterCatalog.adapters[id] else { return nil }
            return Adapter(id: a.id, label: a.displayName, backend: a.backend.rawValue, license: a.license,
                           approxSizeMB: a.approxSizeMB,
                           installed: ImageAdapterCatalog.isInstalled(a, hfCacheRoot: hfCache))
        }
        return ImageEditOptionsResponse(capability: CapabilityID.imageEdit.rawValue, backends: backends, adapters: adapters)
    }
}
