import Foundation

// esh 2.1 UCMR, Stage 3 — capability-specific benchmarks for image generation. Records cold load, warm
// generation, seconds/image, peak/resident memory, resolution, output validity, and stability, with full
// provenance (model, revision, quantization/config, runtime, Mac, memory, resolution, esh version). This
// evidence is designed to feed Scheduler v2 / Auto later — the same role LLM BenchmarkEvidence plays.

/// One generation probe's raw outcome (injected by the caller so the runner is backend-agnostic + testable).
public struct ImageGenProbeOutput: Sendable {
    public var outputWidth: Int
    public var outputHeight: Int
    public var elapsedMs: Double
    public var peakMemoryMB: Double?
    public init(outputWidth: Int, outputHeight: Int, elapsedMs: Double, peakMemoryMB: Double? = nil) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.elapsedMs = elapsedMs
        self.peakMemoryMB = peakMemoryMB
    }
}

public struct ImageGenerationBenchmark: Codable, Hashable, Sendable {
    public var modelID: String
    public var provenance: BenchmarkProvenance
    public var requestedWidth: Int
    public var requestedHeight: Int
    public var steps: Int
    public var coldLoadAndGenerateMs: Double?       // first run: includes model load
    public var warmGenerateMsMedian: Double?        // median of measured runs after cold
    public var secondsPerImageMedian: Double?
    public var peakMemoryMB: Double?
    public var residentMemoryMB: Double?
    public var outputValidCount: Int                // runs producing an image of the requested size
    public var totalRuns: Int
    public var sampleLatenciesMs: [Double]
    public var stable: Bool                          // all runs valid AND latency spread bounded
    /// True when the sample was taken under elevated memory pressure — NOT recommendation-grade; the
    /// Scheduler/Auto must not treat such a sample as a normal performance baseline.
    public var measuredUnderMemoryPressure: Bool
    /// Free-text honest qualifier (e.g. "GPU-compute-bound; 1024² not interactive-grade on M1 Pro").
    public var note: String?

    public init(modelID: String, provenance: BenchmarkProvenance, requestedWidth: Int, requestedHeight: Int,
                steps: Int, coldLoadAndGenerateMs: Double?, warmGenerateMsMedian: Double?,
                secondsPerImageMedian: Double?, peakMemoryMB: Double?, residentMemoryMB: Double?,
                outputValidCount: Int, totalRuns: Int, sampleLatenciesMs: [Double], stable: Bool,
                measuredUnderMemoryPressure: Bool = false, note: String? = nil) {
        self.modelID = modelID
        self.provenance = provenance
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.steps = steps
        self.coldLoadAndGenerateMs = coldLoadAndGenerateMs
        self.warmGenerateMsMedian = warmGenerateMsMedian
        self.secondsPerImageMedian = secondsPerImageMedian
        self.peakMemoryMB = peakMemoryMB
        self.residentMemoryMB = residentMemoryMB
        self.outputValidCount = outputValidCount
        self.totalRuns = totalRuns
        self.sampleLatenciesMs = sampleLatenciesMs
        self.stable = stable
        self.measuredUnderMemoryPressure = measuredUnderMemoryPressure
        self.note = note
    }
}

public struct ImageGenerationBenchmarkDataset: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var benchmarks: [ImageGenerationBenchmark]
    public init(schemaVersion: Int = ImageGenerationBenchmarkDataset.schemaVersion, benchmarks: [ImageGenerationBenchmark] = []) {
        self.schemaVersion = schemaVersion
        self.benchmarks = benchmarks
    }
}

/// JSON-backed persistence for image benchmark evidence, alongside the LLM benchmark dataset.
public struct ImageGenerationBenchmarkStore: Sendable {
    private let fileURL: URL
    public init(root: PersistenceRoot) {
        self.fileURL = root.benchmarksURL.appendingPathComponent("image-generation-benchmarks.json")
    }
    public func load() -> ImageGenerationBenchmarkDataset {
        guard let data = try? Data(contentsOf: fileURL),
              let ds = try? JSONCoding.decoder.decode(ImageGenerationBenchmarkDataset.self, from: data) else {
            return ImageGenerationBenchmarkDataset()
        }
        return ds
    }
    public func save(_ dataset: ImageGenerationBenchmarkDataset) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONCoding.encoder.encode(dataset)
        try data.write(to: fileURL, options: .atomic)
    }
    /// Append a benchmark (newest kept per model+resolution+steps key).
    @discardableResult
    public func upsert(_ benchmark: ImageGenerationBenchmark) throws -> ImageGenerationBenchmarkDataset {
        var ds = load()
        let key: (ImageGenerationBenchmark) -> String = { "\($0.modelID)|\($0.requestedWidth)x\($0.requestedHeight)|\($0.steps)" }
        ds.benchmarks.removeAll { key($0) == key(benchmark) }
        ds.benchmarks.append(benchmark)
        try save(ds)
        return ds
    }
}

public struct ImageGenerationBenchmarkRunner: Sendable {
    public typealias GenerateProbe = @Sendable (_ prompt: String, _ width: Int, _ height: Int, _ steps: Int, _ seed: Int) async throws -> ImageGenProbeOutput

    public static let suiteVersion = 1
    private let generate: GenerateProbe
    public init(generate: @escaping GenerateProbe) { self.generate = generate }

    public static let defaultPrompt = "a watercolor illustration of a fox in the rain"

    /// Run one cold generation (model load + generate) then `measuredRuns` warm generations; compute
    /// medians, validity (image produced at the requested size), and a stability flag.
    public func run(modelID: String, provenance: BenchmarkProvenance, width: Int = 1024, height: Int = 1024,
                    steps: Int = 8, measuredRuns: Int = 3, prompt: String = defaultPrompt) async -> ImageGenerationBenchmark {
        var latencies: [Double] = []
        var validCount = 0
        var coldMs: Double?
        var peakMB: Double?

        func validate(_ out: ImageGenProbeOutput) -> Bool { out.outputWidth == width && out.outputHeight == height }

        // Cold run (includes load).
        if let out = try? await generate(prompt, width, height, steps, 0) {
            coldMs = out.elapsedMs
            if validate(out) { validCount += 1 }
            if let m = out.peakMemoryMB { peakMB = max(peakMB ?? 0, m) }
        }
        // Warm measured runs.
        for i in 0..<max(0, measuredRuns) {
            guard let out = try? await generate(prompt, width, height, steps, i + 1) else { continue }
            latencies.append(out.elapsedMs)
            if validate(out) { validCount += 1 }
            if let m = out.peakMemoryMB { peakMB = max(peakMB ?? 0, m) }
        }

        let warmMedian = Self.median(latencies)
        let totalRuns = (coldMs != nil ? 1 : 0) + latencies.count
        // Stable when every run produced a valid image and the warm latency spread is bounded (<50%).
        let spreadOK: Bool = {
            guard let mn = latencies.min(), let mx = latencies.max(), let med = warmMedian, med > 0 else { return latencies.count <= 1 }
            return (mx - mn) / med < 0.5
        }()
        let stable = totalRuns > 0 && validCount == totalRuns && spreadOK

        return ImageGenerationBenchmark(
            modelID: modelID, provenance: provenance, requestedWidth: width, requestedHeight: height, steps: steps,
            coldLoadAndGenerateMs: coldMs, warmGenerateMsMedian: warmMedian,
            secondsPerImageMedian: warmMedian.map { $0 / 1000 }, peakMemoryMB: peakMB, residentMemoryMB: nil,
            outputValidCount: validCount, totalRuns: totalRuns, sampleLatenciesMs: latencies, stable: stable)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}
