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

@Test
func focusedCalibratedCodeContextPrefersTriAttention() throws {
    let root = PersistenceRoot(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    let locator = TriAttentionCalibrationLocator(root: root)
    let calibrationURL = try locator.ensureDirectory(for: "demo-model")
    try Data("ok".utf8).write(to: calibrationURL)
    let policy = KVModePolicy(calibrationLocator: locator)
    let package = ContextPackage(
        manifest: ContextPackageManifest(
            workspaceRootPath: "/tmp/demo",
            task: "fix refresh bug",
            taskFingerprint: "abc",
            modelID: "demo-model",
            intent: .code,
            cacheMode: .automatic,
            files: [
                ContextPackageFile(path: "Sources/Auth.swift", contentHash: "1"),
                ContextPackageFile(path: "Sources/Token.swift", contentHash: "2")
            ]
        ),
        packagePath: "",
        sizeBytes: 0,
        brief: ContextPlanningBrief(
            task: "fix refresh bug",
            summary: "focused auth context",
            rankedResults: [],
            snippets: [],
            runSummary: nil,
            openQuestions: [],
            suggestedNextSteps: []
        )
    )

    let resolution = policy.resolveMode(
        requestedMode: .automatic,
        intent: .code,
        modelID: "demo-model",
        contextPackage: package
    )

    #expect(resolution.mode == .triattention)
}

@Test
func broadCodeContextPrefersTurboEvenWithCalibration() throws {
    let root = PersistenceRoot(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    let locator = TriAttentionCalibrationLocator(root: root)
    let calibrationURL = try locator.ensureDirectory(for: "demo-model")
    try Data("ok".utf8).write(to: calibrationURL)
    let policy = KVModePolicy(calibrationLocator: locator)
    let files = (1...7).map { ContextPackageFile(path: "Sources/File\($0).swift", contentHash: "\($0)") }
    let package = ContextPackage(
        manifest: ContextPackageManifest(
            workspaceRootPath: "/tmp/demo",
            task: "investigate repo-wide issue",
            taskFingerprint: "xyz",
            modelID: "demo-model",
            intent: .code,
            cacheMode: .automatic,
            files: files
        ),
        packagePath: "",
        sizeBytes: 0,
        brief: ContextPlanningBrief(
            task: "investigate repo-wide issue",
            summary: "broad context",
            rankedResults: [],
            snippets: [],
            runSummary: nil,
            openQuestions: [],
            suggestedNextSteps: []
        )
    )

    let resolution = policy.resolveMode(
        requestedMode: .automatic,
        intent: .code,
        modelID: "demo-model",
        contextPackage: package
    )

    #expect(resolution.mode == .turbo)
}
