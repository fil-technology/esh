import Foundation
import Testing
@testable import EshCore

@Suite
struct ImageModelFitServiceTests {
    private func root() -> PersistenceRoot {
        PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-imgfit-\(UUID().uuidString)"))
    }

    @Test
    func zImageTurboComfortableOn64GB() {
        let svc = ImageModelFitService()
        let host = HostMachineProfile(chipDescription: "Apple M-test", totalMemoryGB: 64, availableMemoryGB: 40, safeBudgetGB: 48)
        let fit = svc.assess(input: .init(weightsGB: 6.5, width: 1024, height: 1024), host: host, root: root())
        #expect(fit.fitClass == .comfortable)
        #expect((fit.estimatedPeakMemoryGB ?? 0) > 6.5)         // weights + working + overhead
        #expect(fit.breakdown["working@1024x1024"] != nil)
    }

    @Test
    func higherResolutionRaisesPeakMemory() {
        let lo = ImageModelFitService.workingMemoryGB(width: 512, height: 512)
        let hi = ImageModelFitService.workingMemoryGB(width: 2048, height: 2048)
        #expect(hi > lo)
    }

    @Test
    func tightOrUnlikelyOnSmallMemory() {
        let svc = ImageModelFitService()
        let host = HostMachineProfile(chipDescription: "Apple M-test", totalMemoryGB: 8, availableMemoryGB: 6, safeBudgetGB: 3)
        let fit = svc.assess(input: .init(weightsGB: 6.5, width: 1024, height: 1024), host: host, root: root())
        #expect(fit.fitClass == .tight || fit.fitClass == .unlikely)
        #expect(fit.requiresConfirmation)
    }

    @Test
    func unknownWhenWeightsUnknown() {
        let svc = ImageModelFitService()
        let host = HostMachineProfile(totalMemoryGB: 32, availableMemoryGB: 20, safeBudgetGB: 24)
        let fit = svc.assess(input: .init(weightsGB: nil), host: host, root: root())
        #expect(fit.fitClass == .unknown)
    }

    @Test
    func unsupportedWhenBackendMissing() {
        let svc = ImageModelFitService()
        let host = HostMachineProfile(totalMemoryGB: 32, availableMemoryGB: 20, safeBudgetGB: 24)
        let fit = svc.assess(input: .init(weightsGB: 6.5, backendSupported: false), host: host, root: root())
        #expect(fit.fitClass == .unsupported)
        #expect(fit.isBlocked)
    }
}
