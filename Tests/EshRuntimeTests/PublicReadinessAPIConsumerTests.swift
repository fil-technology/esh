// External-consumer compile test for the live model-readiness API.
//
// This file imports EshRuntime / EshCore WITHOUT `@testable` — exactly as an external consumer
// (e.g. esh Studio) does — so it sees only the PUBLIC surface. If `EshRuntime.modelOptions(for:)`
// (or any type in its signature) were not public, this file would fail to compile. That compile
// failure is the test.
import Testing
import Foundation
import EshCore
import EshRuntime

// Referencing the API from a non-@testable file is the actual assertion: it must resolve against
// public visibility only. Not executed against a live runtime — this guards the API SHAPE/visibility.
private func _externalConsumerCanCallReadinessAPI(_ runtime: EshRuntime) async -> [ModelOptionAvailability] {
    await runtime.modelOptions(for: CapabilityID("audio.synthesizeSpeech"))
}

// The public readiness types an external consumer renders must also be reachable here.
private func _externalConsumerCanReadAvailabilityFields(_ a: ModelOptionAvailability) -> (ModelOptionReadiness, ModelOptionFit, Int64?, String) {
    (a.readiness, a.fit, a.sizeBytes, a.note)
}

struct PublicReadinessAPIConsumerTests {
    /// Anchors the compile-time checks above (their successful compilation proves public visibility).
    @Test func readinessAPIIsPublicToExternalConsumers() {
        #expect(true)
    }
}
