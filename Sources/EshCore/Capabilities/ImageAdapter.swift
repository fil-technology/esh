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
        "3d-animation": ImageAdapter(
            id: "3d-animation", displayName: "3D animation style",
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
