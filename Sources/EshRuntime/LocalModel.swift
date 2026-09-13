import Foundation
import EshCore

// esh M8 — iOS local model management (data types). Model management, not a marketplace.
// A curated, data-driven descriptor layer + install lifecycle over the EXISTING esh abstractions
// (ModelSpec/ModelInstall/ModelStore/StorageService/ModelFit/DeviceProfile). Execution stays in the
// app-injected LlamaCppEmbeddedBackend; nothing here imports llama.cpp.

/// A curated, verifiable GGUF model an iOS app can install. Integrity + provenance travel with it.
public struct LocalModelDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: String                       // stable esh model id (used for pinning)
    public let displayName: String
    public let sourceURL: URL                   // direct file URL (GGUF)
    public let repository: String               // provenance, e.g. "bartowski/Qwen2.5-1.5B-Instruct-GGUF"
    public let license: String                  // e.g. "apache-2.0"
    public let expectedBytes: Int64
    public let sha256: String                   // lowercase hex
    public let quantization: String             // e.g. "Q4_K_M"
    public let parameterCountB: Double          // e.g. 1.5
    public let capability: String               // e.g. "text-generation"
    public let recommendedContext: Int          // bounded context to run at
    public let recommendedHardwareClass: String // human hint, e.g. "iPhone 8GB+"

    public init(id: String, displayName: String, sourceURL: URL, repository: String, license: String,
                expectedBytes: Int64, sha256: String, quantization: String, parameterCountB: Double,
                capability: String = "text-generation", recommendedContext: Int = 2048,
                recommendedHardwareClass: String) {
        self.id = id; self.displayName = displayName; self.sourceURL = sourceURL
        self.repository = repository; self.license = license; self.expectedBytes = expectedBytes
        self.sha256 = sha256.lowercased(); self.quantization = quantization
        self.parameterCountB = parameterCountB; self.capability = capability
        self.recommendedContext = recommendedContext; self.recommendedHardwareClass = recommendedHardwareClass
    }

    /// The `ModelSpec` this descriptor installs as (backend = .gguf), reusing esh's model contracts.
    public func makeSpec(localPath: String? = nil) -> ModelSpec {
        ModelSpec(id: id, displayName: displayName, backend: .gguf,
                  source: ModelSource(kind: .huggingFace, reference: repository),
                  localPath: localPath, baseModelID: repository, variant: quantization)
    }
}

/// The smallest curated catalog — data-driven so adding a model needs no code changes to the manager.
/// GGUF file sizes/SHA-256 are the exact upstream LFS values (1.5B cross-checked against the M7 benchmark).
public enum LocalModelCatalog {
    public static let models: [LocalModelDescriptor] = [
        LocalModelDescriptor(
            id: "qwen2.5-0.5b-instruct-q4km",
            displayName: "Qwen2.5 0.5B Instruct (Q4_K_M)",
            sourceURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf")!,
            repository: "bartowski/Qwen2.5-0.5B-Instruct-GGUF", license: "apache-2.0",
            expectedBytes: 397_808_192, sha256: "6eb923e7d26e9cea28811e1a8e852009b21242fb157b26149d3b188f3a8c8653",
            quantization: "Q4_K_M", parameterCountB: 0.5, recommendedContext: 2048,
            recommendedHardwareClass: "any 4GB+ iPhone"),
        LocalModelDescriptor(
            id: "qwen2.5-1.5b-instruct-q4km",
            displayName: "Qwen2.5 1.5B Instruct (Q4_K_M)",
            sourceURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf")!,
            repository: "bartowski/Qwen2.5-1.5B-Instruct-GGUF", license: "apache-2.0",
            expectedBytes: 986_048_768, sha256: "1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370",
            quantization: "Q4_K_M", parameterCountB: 1.5, recommendedContext: 2048,
            recommendedHardwareClass: "iPhone 8GB+"),
    ]
    public static func descriptor(id: String) -> LocalModelDescriptor? { models.first { $0.id == id } }
}

// Ergonomic named descriptors so a host can write `runtime.install(.qwen05B)` without knowing catalog ids.
// These are the curated catalog entries; `LocalModelCatalog.models` remains the source of truth.
public extension LocalModelDescriptor {
    /// Qwen2.5 0.5B Instruct (Q4_K_M) — ~380 MB, comfortable on any 4GB+ iPhone.
    static var qwen05B: LocalModelDescriptor { LocalModelCatalog.descriptor(id: "qwen2.5-0.5b-instruct-q4km")! }
    /// Qwen2.5 1.5B Instruct (Q4_K_M) — ~940 MB, recommended for 8GB+ iPhones.
    static var qwen15B: LocalModelDescriptor { LocalModelCatalog.descriptor(id: "qwen2.5-1.5b-instruct-q4km")! }
}

/// Install lifecycle state for a model.
public enum LocalModelState: Sendable, Equatable {
    case notInstalled
    case downloading(progress: Double)   // 0...1
    case paused(bytesDownloaded: Int64)  // resumable partial present
    case verifying
    case installed
    case failed(reason: String)
}

/// A model + its current state, for `runtime.localModels()`.
public struct LocalModelStatus: Sendable, Equatable {
    public let descriptor: LocalModelDescriptor
    public let state: LocalModelState
    public init(descriptor: LocalModelDescriptor, state: LocalModelState) {
        self.descriptor = descriptor; self.state = state
    }
}

/// Preflight result: is it safe to download AND to run?
public struct LocalModelInstallPlan: Sendable, Equatable {
    public let descriptor: LocalModelDescriptor
    public let downloadBytes: Int64
    public let availableStorageBytes: Int64?
    public let storageSafetyReserveBytes: Int64
    public let storageSufficient: Bool
    public let fit: ModelFitClass
    public let suitable: Bool                 // storageSufficient && fit not unsupported/unlikely-hard
    public let reasons: [String]
    public init(descriptor: LocalModelDescriptor, downloadBytes: Int64, availableStorageBytes: Int64?,
                storageSafetyReserveBytes: Int64, storageSufficient: Bool, fit: ModelFitClass,
                suitable: Bool, reasons: [String]) {
        self.descriptor = descriptor; self.downloadBytes = downloadBytes
        self.availableStorageBytes = availableStorageBytes
        self.storageSafetyReserveBytes = storageSafetyReserveBytes
        self.storageSufficient = storageSufficient; self.fit = fit
        self.suitable = suitable; self.reasons = reasons
    }
}

public enum LocalModelError: Error, Sendable, Equatable, LocalizedError {
    case unknownModel(String)
    case insufficientStorage(needBytes: Int64, freeBytes: Int64?)
    case alreadyInstalled(String)
    case notInstalled(String)
    case contentLengthMismatch(expected: Int64, got: Int64)
    case checksumMismatch(expected: String, got: String)
    case downloadFailed(String)
    case installFileMissing(String)
    /// A concurrent install of the same model is already running (M10). The second caller fails fast
    /// rather than starting a duplicate download.
    case installInProgress(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownModel(id): return "Unknown model '\(id)'."
        case let .insufficientStorage(need, free): return "Insufficient storage: need \(need) bytes, free \(free.map(String.init) ?? "unknown")."
        case let .alreadyInstalled(id): return "Model '\(id)' is already installed."
        case let .notInstalled(id): return "Model '\(id)' is not installed."
        case let .contentLengthMismatch(e, g): return "Download size mismatch: expected \(e), got \(g)."
        case let .checksumMismatch(e, g): return "Checksum mismatch: expected \(e), got \(g)."
        case let .downloadFailed(m): return "Download failed: \(m)"
        case let .installFileMissing(id): return "Install record for '\(id)' exists but the model file is missing."
        case let .installInProgress(id): return "Model '\(id)' is already being installed."
        }
    }
}
