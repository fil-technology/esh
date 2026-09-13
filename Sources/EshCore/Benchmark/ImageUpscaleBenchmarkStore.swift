import Foundation

// Portable image.upscale benchmark evidence store. Extracted from ImageUpscaleBenchmark.swift
// (esh iOS M1): the persisted evidence is read by the portable scheduler / Model Fit / evidence
// index, while the benchmark RUNNER (which drives the macOS-only upscale service) stays guarded.
public struct UpscaleBenchmarkDataset: Codable, Sendable {
    public var evidence: [CapabilityPerformanceEvidence]
    public init(evidence: [CapabilityPerformanceEvidence] = []) { self.evidence = evidence }
}

public struct ImageUpscaleBenchmarkStore: Sendable {
    private let fileURL: URL
    public init(root: PersistenceRoot) {
        self.fileURL = root.benchmarksURL.appendingPathComponent("image-upscale-benchmarks.json")
    }
    public func load() -> UpscaleBenchmarkDataset {
        guard let data = try? Data(contentsOf: fileURL),
              let ds = try? JSONCoding.decoder.decode(UpscaleBenchmarkDataset.self, from: data) else { return UpscaleBenchmarkDataset() }
        return ds
    }
    public func save(_ ds: UpscaleBenchmarkDataset) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(ds).write(to: fileURL, options: .atomic)
    }
    /// Newest kept per provider+config key (e.g. "image-upscale|512x512|scale=2").
    @discardableResult
    public func upsert(_ e: CapabilityPerformanceEvidence) throws -> UpscaleBenchmarkDataset {
        var ds = load()
        let key: (CapabilityPerformanceEvidence) -> String = { ev in
            let w = ev.config["width"].flatMap { if case let .int(i) = $0 { return i } else { return nil } } ?? 0
            let h = ev.config["height"].flatMap { if case let .int(i) = $0 { return i } else { return nil } } ?? 0
            let s = ev.config["scale"].flatMap { if case let .int(i) = $0 { return i } else { return nil } } ?? 0
            return "\(ev.providerID)|\(w)x\(h)|scale=\(s)"
        }
        ds.evidence.removeAll { key($0) == key(e) }
        ds.evidence.append(e)
        try save(ds)
        return ds
    }
}
