import Foundation
import Testing
@testable import EshCore

@Suite
struct OnboardingServiceTests {
    @Test
    func stateStoreDefaultsToNotCompleted() {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let state = OnboardingStateStore(root: root).load()
        #expect(!state.completed)
    }

    @Test
    func markCompletedPersistsAndIsReReadable() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let service = OnboardingService()
        #expect(!service.hasCompleted(root: root))

        try service.markCompleted(root: root, selectedModelID: "qwen-3-5-9b", storageMode: "external")
        #expect(service.hasCompleted(root: root))

        let reloaded = OnboardingStateStore(root: root).load()
        #expect(reloaded.completed)
        #expect(reloaded.selectedModelID == "qwen-3-5-9b")
        #expect(reloaded.storageMode == "external")
        #expect(reloaded.completedAtISO8601 != nil)
        #expect(reloaded.version == OnboardingState.currentVersion)
    }

    @Test
    func reRunIsSafeAndUpdatesSelection() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let service = OnboardingService()
        try service.markCompleted(root: root, selectedModelID: "a", storageMode: "internal")
        try service.markCompleted(root: root, selectedModelID: "b", storageMode: "internal")
        #expect(OnboardingStateStore(root: root).load().selectedModelID == "b")
    }

    @Test
    func recommendationsPreferMLXWhenReadyAndFitBudget() {
        let env = OnboardingEnvironment(
            host: HostMachineProfile(totalMemoryGB: 16, availableMemoryGB: 10, safeBudgetGB: 6),
            macOS: "26.0.0",
            mlxReady: true,
            llamaCppReady: true,
            storage: StorageService().report(root: PersistenceRoot(rootURL: temporaryDirectory())),
            installedModelCount: 0,
            installedModelIDs: [],
            appleIntelligence: AppleIntelligenceStatus(available: false, availability: .frameworkUnavailable, detail: "test", onDevice: true)
        )
        let recs = OnboardingService().recommendations(useCase: .general, environment: env)
        #expect(!recs.isEmpty)
        #expect(recs.allSatisfy { $0.backend == .mlx })
        #expect(recs.allSatisfy { $0.estimatedMemoryGB <= 6 })
    }

    @Test
    func recommendationsFallBackToGGUFWhenOnlyLlamaReady() {
        let env = OnboardingEnvironment(
            host: HostMachineProfile(totalMemoryGB: 16, availableMemoryGB: 10, safeBudgetGB: 8),
            macOS: "26.0.0",
            mlxReady: false,
            llamaCppReady: true,
            storage: StorageService().report(root: PersistenceRoot(rootURL: temporaryDirectory())),
            installedModelCount: 0,
            installedModelIDs: [],
            appleIntelligence: AppleIntelligenceStatus(available: false, availability: .frameworkUnavailable, detail: "test", onDevice: true)
        )
        let recs = OnboardingService().recommendations(useCase: .general, environment: env)
        #expect(!recs.isEmpty)
        #expect(recs.allSatisfy { $0.backend == .gguf })
    }

    @Test
    func missingEngineHelpAppearsWhenNoEngineReady() {
        let env = OnboardingEnvironment(
            host: HostMachineProfile(),
            macOS: "26.0.0",
            mlxReady: false,
            llamaCppReady: false,
            storage: StorageService().report(root: PersistenceRoot(rootURL: temporaryDirectory())),
            installedModelCount: 0,
            installedModelIDs: [],
            appleIntelligence: AppleIntelligenceStatus(available: false, availability: .frameworkUnavailable, detail: "test", onDevice: true)
        )
        #expect(!env.hasUsableEngine)
        #expect(env.missingEngineHelp != nil)
    }

    @Test
    func detectEnvironmentReportsNoInstallsForFreshRoot() {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let env = OnboardingService().detectEnvironment(root: root)
        #expect(env.installedModelCount == 0)
        #expect(!env.macOS.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
