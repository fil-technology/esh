import Foundation
import Testing
@testable import EshCore

private func gateInstall(_ id: String, gib: Double) -> ModelInstall {
    let spec = ModelSpec(id: id, displayName: id, backend: .mlx, source: ModelSource(kind: .localPath, reference: "local/\(id)"))
    return ModelInstall(id: id, spec: spec, installPath: "/tmp/\(id)", sizeBytes: Int64(gib * 1_073_741_824), backendFormat: "mlx")
}

private func host(totalGB: Double = 32, availableGB: Double?, systemFreeGB: Double?, critical: Bool = false) -> HostResources {
    HostResources(totalMemoryGB: totalGB, availableMemoryGB: availableGB, systemVolumeFreeGB: systemFreeGB,
                  assetsVolumeFreeGB: 100, assetsVolumeAvailable: true, residentHeavyMemoryGB: 0, memoryCritical: critical)
}

@Suite struct ModelLoadSafetyGateTests {
    @Test func smallModelsAreNeverGated() {
        #expect(ModelLoadSafetyGate.verdict(for: gateInstall("tiny-model-x", gib: 1), host: host(availableGB: 0.5, systemFreeGB: 0.1)).fits)
    }

    @Test func bigModelWithoutSwapHeadroomIsGated() {
        let v = ModelLoadSafetyGate.verdict(for: gateInstall("big-unknown-model", gib: 16), host: host(availableGB: 8, systemFreeGB: 4))
        #expect(!v.fits)
    }

    @Test func bigModelThatFitsAvailableMemoryPasses() {
        #expect(ModelLoadSafetyGate.verdict(for: gateInstall("big-unknown-model", gib: 16), host: host(availableGB: 20, systemFreeGB: 4)).fits)
    }

    @Test func additionalResidentCacheCountsTowardThePeak() {
        let i = gateInstall("mid-unknown-model", gib: 10)
        #expect(ModelLoadSafetyGate.verdict(for: i, host: host(availableGB: 11, systemFreeGB: 2)).fits)
        #expect(!ModelLoadSafetyGate.verdict(for: i, additionalGB: 4, host: host(availableGB: 11, systemFreeGB: 2)).fits)
    }

    @Test func requiredPeakUsesDiskSizeProxyForUnknownModels() {
        let gb = ModelLoadSafetyGate.requiredPeakGB(for: gateInstall("unknown-xyz", gib: 10))
        #expect(abs(gb - 10.5) < 0.01)
    }
}

