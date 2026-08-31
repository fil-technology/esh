import Foundation
import Testing
@testable import EshCore

@Suite
struct ModelFitServiceTests {
    private func host(gb: Double, chip: String = "Apple M-test") -> HostMachineProfile {
        HostMachineProfile(chipDescription: chip, totalMemoryGB: gb, availableMemoryGB: gb * 0.5, safeBudgetGB: gb * 0.6)
    }

    private func input(paramsB: Double?, bits: Double? = 4.5, ctx: Int = 8192, diskGB: Double = 5, backendOK: Bool = true, archOK: Bool = true) -> ModelFitService.Input {
        ModelFitService.Input(
            parameterCountB: paramsB, effectiveBits: bits, format: .mlx, backend: .mlx,
            backendSupported: backendOK, architectureSupported: archOK,
            contextTokens: ctx, diskRequiredBytes: Int64(diskGB * 1_073_741_824)
        )
    }

    private func assess(_ inp: ModelFitService.Input, gb: Double) -> ModelFitAssessment {
        ModelFitService().assess(input: inp, host: host(gb: gb), root: PersistenceRoot(rootURL: tempDir()))
    }

    @Test
    func classesScaleWithMemory() {
        // A ~14B 4-bit model (~9 GB peak) across memory classes.
        #expect(assess(input(paramsB: 14), gb: 8).fitClass == .unlikely)     // 8 GB Mac
        // 16 GB: ~9 GB peak vs ~12.8 usable -> fits
        #expect([.fits, .tight].contains(assess(input(paramsB: 14), gb: 16).fitClass))
        // 32 GB: comfortable
        #expect(assess(input(paramsB: 14), gb: 32).fitClass == .comfortable)
        // 64 GB: comfortable
        #expect(assess(input(paramsB: 14), gb: 64).fitClass == .comfortable)
    }

    @Test
    func hugeModelIsUnlikelyNotBlockedOnBigMac() {
        // A 70B 4-bit (~44 GB) on a 32 GB Mac: unlikely, but NOT unsupported (override allowed).
        let a = assess(input(paramsB: 70, diskGB: 40), gb: 32)
        #expect(a.fitClass == .unlikely)
        #expect(!a.isBlocked)                       // knowledgeable users may still try
        #expect(a.requiresConfirmation)
    }

    @Test
    func longContextGrowsPeakMemory() {
        let short = assess(input(paramsB: 14, ctx: 2048), gb: 24)
        let long = assess(input(paramsB: 14, ctx: 32768), gb: 24)
        #expect((long.estimatedPeakMemoryGB ?? 0) > (short.estimatedPeakMemoryGB ?? 0))
    }

    @Test
    func unsupportedBackendIsBlocked() {
        let a = assess(input(paramsB: 3, backendOK: false), gb: 32)
        #expect(a.fitClass == .unsupported)
        #expect(a.isBlocked)
        #expect(!a.blockers.isEmpty)
    }

    @Test
    func unknownMetadataIsUnknownNotBlocked() {
        let a = assess(input(paramsB: nil, bits: nil), gb: 32)
        #expect(a.fitClass == .unknown)
        #expect(!a.isBlocked)
        #expect(a.requiresConfirmation)             // allow deliberate override
    }

    @Test
    func insufficientDiskRequiresConfirmation() {
        // Require 100 GB on a root whose volume has far less free.
        let a = assess(input(paramsB: 3, diskGB: 100), gb: 32)
        #expect(!a.diskSufficient)
        #expect(a.requiresConfirmation)
    }

    @Test
    func competingResidentModelReducesFit() {
        let base = ModelFitService.Input(parameterCountB: 14, effectiveBits: 4.5, format: .mlx, backend: .mlx, contextTokens: 8192, diskRequiredBytes: nil, otherResidentGB: 0)
        let withResident = ModelFitService.Input(parameterCountB: 14, effectiveBits: 4.5, format: .mlx, backend: .mlx, contextTokens: 8192, diskRequiredBytes: nil, otherResidentGB: 12)
        let a = ModelFitService().assess(input: base, host: host(gb: 24), root: PersistenceRoot(rootURL: tempDir()))
        let b = ModelFitService().assess(input: withResident, host: host(gb: 24), root: PersistenceRoot(rootURL: tempDir()))
        #expect((b.estimatedPeakMemoryGB ?? 0) > (a.estimatedPeakMemoryGB ?? 0))
    }

    @Test
    func parsingHelpers() {
        #expect(ModelFitService.parseParameterCount("9B") == 9)
        #expect(ModelFitService.parseParameterCount("0.5B") == 0.5)
        #expect(ModelFitService.parseParameterCount("500M") == 0.5)
        #expect(ModelFitService.parseEffectiveBits("4-bit") == 4.5)
        #expect(ModelFitService.parseEffectiveBits("Q8_0") == 8)
        #expect(ModelFitService.parseEffectiveBits("fp16") == 16)
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
