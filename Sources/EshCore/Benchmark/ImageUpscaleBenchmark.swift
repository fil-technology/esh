import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

// esh 2.1 — Stage 3: real image.upscale performance evidence. Runs the working Real-ESRGAN path over
// realistic image sizes × scales on THIS Mac, measures cold/warm/execution/peak-memory, and persists the
// unified CapabilityPerformanceEvidence so Model Fit / Scheduler can prefer a *practical* config (memory
// fit ≠ useful performance). No fabricated numbers — every row is a measured run.

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

public struct ImageUpscaleBenchmarkRunner: Sendable {
    public struct Config: Sendable { public let width: Int; public let scale: Int
        public init(width: Int, scale: Int) { self.width = width; self.scale = scale } }

    private let service: ImageUpscaleService
    private let modelDir: String
    public init(service: ImageUpscaleService = .init(), modelDir: String) {
        self.service = service; self.modelDir = modelDir
    }

    /// Run each config once "cold" (fresh subprocess) and once "warm" (repeat). Returns measured evidence
    /// (also persisted by the caller). `tmpDir` holds generated inputs + outputs. A failing config is
    /// recorded with reliability 0 and a note rather than aborting the whole run.
    public func run(configs: [Config], tmpDir: URL, provenanceNote: String? = nil) -> [CapabilityPerformanceEvidence] {
        var out: [CapabilityPerformanceEvidence] = []
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        for cfg in configs {
            let inPath = tmpDir.appendingPathComponent("in-\(cfg.width).png").path
            if !FileManager.default.fileExists(atPath: inPath) {
                guard (try? Self.writeGradientPNG(width: cfg.width, height: cfg.width, to: inPath)) != nil else {
                    out.append(Self.failed(cfg, note: "could not synthesize test image")); continue
                }
            }
            do {
                let outCold = tmpDir.appendingPathComponent("out-cold-\(cfg.width)-\(cfg.scale).png").path
                let t0 = Date()
                let r1 = try service.upscale(imagePath: inPath, outputPath: outCold, scale: cfg.scale, modelDir: modelDir, minFreeMemMB: nil)
                let coldMs = Date().timeIntervalSince(t0) * 1000
                let outWarm = tmpDir.appendingPathComponent("out-warm-\(cfg.width)-\(cfg.scale).png").path
                let t1 = Date()
                let r2 = try service.upscale(imagePath: inPath, outputPath: outWarm, scale: cfg.scale, modelDir: modelDir, minFreeMemMB: nil)
                let warmMs = Date().timeIntervalSince(t1) * 1000
                out.append(CapabilityPerformanceEvidence(
                    capability: .imageUpscale, providerID: "image-upscale", modelID: "SceneWorks/real-esrgan-onnx",
                    config: ["width": .int(cfg.width), "height": .int(cfg.width), "scale": .int(cfg.scale),
                             "outWidth": .int(r2.width), "outHeight": .int(r2.height), "tiled": .bool(r2.tiled)],
                    coldMs: coldMs, warmMs: warmMs, secondsPerUnit: warmMs / 1000.0, unit: "image",
                    peakMemoryMB: r2.peakMemoryMB ?? r1.peakMemoryMB, reliability: 1.0,
                    experimental: false, note: [provenanceNote, "runtime=\(r2.runtimeProvider)"].compactMap { $0 }.joined(separator: "; ")))
            } catch {
                out.append(Self.failed(cfg, note: "run failed: \(error.localizedDescription)"))
            }
        }
        return out
    }

    private static func failed(_ cfg: Config, note: String) -> CapabilityPerformanceEvidence {
        CapabilityPerformanceEvidence(
            capability: .imageUpscale, providerID: "image-upscale", modelID: "SceneWorks/real-esrgan-onnx",
            config: ["width": .int(cfg.width), "height": .int(cfg.width), "scale": .int(cfg.scale)],
            unit: "image", reliability: 0.0, note: note)
    }

    /// Synthesize a deterministic gradient+shape PNG at the given size (CoreGraphics) — a realistic,
    /// dependency-free upscale input. Used only to generate benchmark inputs.
    static func writeGradientPNG(width: Int, height: Int, to path: String) throws {
        #if canImport(CoreGraphics)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CapabilityError.failed("could not create bitmap context")
        }
        for y in 0..<height {
            let t = CGFloat(y) / CGFloat(max(height - 1, 1))
            ctx.setFillColor(red: t, green: 0.4, blue: 1 - t, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        ctx.setStrokeColor(red: 1, green: 1, blue: 0, alpha: 1)
        ctx.setLineWidth(CGFloat(max(width / 80, 2)))
        ctx.strokeEllipse(in: CGRect(x: width / 6, y: height / 6, width: width * 2 / 3, height: height * 2 / 3))
        guard let img = ctx.makeImage() else { throw CapabilityError.failed("could not render image") }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
            throw CapabilityError.failed("could not create PNG destination")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CapabilityError.failed("could not write PNG") }
        #else
        throw CapabilityError.failed("CoreGraphics unavailable")
        #endif
    }
}
