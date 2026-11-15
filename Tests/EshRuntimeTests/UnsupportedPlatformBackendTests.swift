import Foundation
import Testing
import EshCore
@testable import EshRuntime

// The iOS `MLXBackend` stub (EshMLXText, compiled only on iOS) delegates all behavior to `UnsupportedPlatformBackend`,
// which is portable, so these macOS tests prove what an iOS host gets for MLX: nothing advertised, nothing executed,
// explicit unsupported-platform errors.

private let reason = "MLX text models run through a Python worker process, which is macOS-only."
private let mlxBackend = UnsupportedPlatformBackend(kind: .mlx, reason: reason)

private func mlxInstall(_ id: String = "mlx-model") -> ModelInstall {
    ModelInstall(id: id, spec: ModelSpec(id: id, displayName: id, backend: .mlx, source: ModelSource(kind: .localPath, reference: id)),
                 installPath: "/tmp/\(id)", sizeBytes: 1_000_000, backendFormat: "mlx")
}

private func runtime(lifecycle: EshRuntimeLifecycle, apple: Bool = false) -> EshRuntime {
    var backends: [BackendKind: any InferenceBackend] = [.mlx: mlxBackend]
    if apple { backends[.apple] = AppleBackend() }
    return EshRuntime(registry: InferenceBackendRegistry(backends: backends),
                      installProvider: StaticInstallProvider([mlxInstall()]), lifecycle: lifecycle)
}

private func isBackendUnavailable(_ error: Error, _ kind: BackendKind) -> Bool {
    if case let EshRuntimeError.backendUnavailable(k, r) = error { return k == kind && r == reason }
    return false
}

@Suite struct UnsupportedPlatformBackendTests {

    @Test func advertisesNothing() {
        let report = mlxBackend.capabilityReport(for: mlxInstall())
        #expect(report.ready == false)
        #expect(report.supportedFeatures.isEmpty)
        #expect(Set(report.unavailableFeatures.map(\.feature)) == Set(BackendRuntimeFeature.allCases))
        #expect(report.unavailableFeatures.allSatisfy { $0.reason == reason })
        #expect(report.warnings == [reason])
        let traits = mlxBackend.lifecycleTraits
        #expect(!traits.supportsIOS && !traits.inProcess && traits.prefixReuse == .none && traits.residency == .handleCached)
    }

    @Test func neverExecutes() async throws {
        await #expect(throws: BackendUnsupportedOnPlatformError(backend: .mlx, reason: reason)) {
            _ = try await mlxBackend.loadRuntime(for: mlxInstall())
        }
        #expect(throws: BackendUnsupportedOnPlatformError.self) {
            try mlxBackend.makeCompatibilityChecker(for: mlxInstall()).validate(manifest: CacheManifest(
                backend: .mlx, modelID: "mlx-model", architectureFingerprint: "x", runtimeVersion: "x",
                cacheFormatVersion: "1", cacheMode: .raw, sessionID: UUID(), sessionName: "s"))
        }
    }

    @Test(arguments: [EshRuntimeLifecycle.oneShot, .managed()])
    func pinnedModelFailsWithBackendUnavailable(lifecycle: EshRuntimeLifecycle) async throws {
        let rt = runtime(lifecycle: lifecycle)
        let request = EshGenerationRequest(prompt: "hi", constraints: .pinned("mlx-model"))
        do { _ = try await rt.generate(request); Issue.record("generate ran on an unsupported backend") }
        catch { #expect(isBackendUnavailable(error, .mlx), "\(error)") }
        do { for try await _ in rt.stream(request) {}; Issue.record("stream ran on an unsupported backend") }
        catch { #expect(isBackendUnavailable(error, .mlx), "\(error)") }
        do { try await rt.prewarm(modelID: "mlx-model"); if case .managed = lifecycle { Issue.record("prewarm loaded") } }
        catch { #expect(isBackendUnavailable(error, .mlx), "\(error)") }
        // Nothing reached a pool.
        #expect(await rt.runtimeStatus().pool?.residents.isEmpty ?? true)
    }

    @Test func autoNeverSelectsIt() async throws {
        let rt = runtime(lifecycle: .managed())
        await #expect(throws: EshRuntimeError.self) { _ = try await rt.generate(EshGenerationRequest(prompt: "hi")) }
        #expect(await rt.capabilities().backends.first { $0.backend == .mlx }?.report.ready == false)
    }

    @Test func readinessSaysUnsupportedOnPlatform() async throws {
        let rt = runtime(lifecycle: .oneShot)
        let r = await rt.textModelReadiness("mlx-model")
        #expect(r.state == .unsupportedOnPlatform)
        #expect(r.reason == reason)
        #expect(!r.canRunNow)
        #expect(await rt.runtimeStatus().backends[.mlx]?.supportsIOS == false)
    }
}
