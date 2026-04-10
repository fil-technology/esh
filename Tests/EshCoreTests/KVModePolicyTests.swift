import Foundation
import Testing
@testable import EshCore

@Test
func automaticCodeIntentPrefersTurboWithoutCalibration() {
    let root = PersistenceRoot(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    let locator = TriAttentionCalibrationLocator(root: root)
    let policy = KVModePolicy(calibrationLocator: locator)

    let resolved = policy.resolvedMode(
        requestedMode: .automatic,
        intent: .code,
        modelID: "demo-model"
    )

    #expect(resolved == .turbo)
}

@Test
func automaticDocumentQAIntentPrefersTurbo() {
    let root = PersistenceRoot(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    let locator = TriAttentionCalibrationLocator(root: root)
    let policy = KVModePolicy(calibrationLocator: locator)

    let resolved = policy.resolvedMode(
        requestedMode: .automatic,
        intent: .documentQA,
        modelID: "demo-model"
    )

    #expect(resolved == .turbo)
}
