import Foundation
import Testing
@testable import EshCore

@Suite
struct AppleIntelligenceServiceTests {
    @Test
    func statusIsWellFormedAndConsistent() {
        let status = AppleIntelligenceService().status()
        // `available` must agree with the availability enum.
        #expect(status.available == (status.availability == .available))
        #expect(!status.detail.isEmpty)
        // On-device provider, never conflated with Private Cloud Compute.
        #expect(status.onDevice)
        // If unavailable, a reason is provided (and usually a fix).
        if !status.available {
            #expect(status.availability != .available)
        }
    }

    @Test
    func statusRoundTripsThroughJSON() throws {
        let status = AppleIntelligenceService().status()
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(AppleIntelligenceStatus.self, from: data)
        #expect(decoded == status)
    }

    @Test
    func generateThrowsWhenUnavailable() async {
        // When Apple Intelligence is unavailable on this machine/build, generate() must throw a
        // clear error rather than silently degrading. (When available, this test simply skips the
        // assertion — generation is exercised manually/on-device.)
        let service = AppleIntelligenceService()
        if !service.status().available {
            await #expect(throws: AppleIntelligenceService.GenerationError.self) {
                _ = try await service.generate(prompt: "hi")
            }
        }
    }

    @Test
    func availabilityEnumCoversKnownReasons() {
        // Guard against accidental raw-value drift consumed by doctor/onboarding JSON.
        #expect(AppleIntelligenceAvailability.available.rawValue == "available")
        #expect(AppleIntelligenceAvailability.deviceNotEligible.rawValue == "deviceNotEligible")
        #expect(AppleIntelligenceAvailability.modelNotReady.rawValue == "modelNotReady")
    }
}
