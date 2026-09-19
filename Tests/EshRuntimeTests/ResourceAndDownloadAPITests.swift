import Foundation
import Testing
import EshCore
@testable import EshRuntime

// rc.21 — public runtime-resource + download-lifecycle facade. Deterministic: mock providers, fake device
// profile, injected install/discard closures + a fake clock. No MLX, no network.

private let GB = 1_073_741_824.0

// MARK: - Test doubles

private final class MockResidentProvider: CapabilityProvider, ResourceStateReporting, @unchecked Sendable {
    let descriptor: CapabilityProviderDescriptor
    let box: ProviderStateBox
    init(id: String, capability: CapabilityID, estimatedGB: Double?, warm: Bool, active: Bool = false) {
        let profile = estimatedGB.map { CapabilityResourceProfile(estimatedPeakMemoryGB: $0, qualityTier: 100) }
        descriptor = CapabilityProviderDescriptor(id: id, capabilities: [capability], acceptedInputs: [.text],
            producedOutputs: [.image], backend: .mlx, modelFamily: "\(id)-fam", resourceProfile: profile)
        box = ProviderStateBox(ProviderRuntimeState(installed: true, warm: warm, active: active))
    }
    var resourceState: ProviderRuntimeState { box.state }
    func execute(_ r: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func unload() async { box.setWarm(false) }
}

private struct FakeDeviceProfile: DeviceProfileProviding {
    let physical: UInt64; let available: UInt64?
    func currentProfile() -> DeviceProfile {
        DeviceProfile(platform: .macOS, physicalMemoryBytes: physical, availableMemoryBytes: available,
                      availableMemoryKind: .systemAvailable, availableStorageBytes: nil, thermalState: .nominal,
                      lowPowerModeEnabled: false, supportsAppleFoundationModels: false, osVersion: "test")
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ nv: Bool) { lock.lock(); v = nv; lock.unlock() }
}
private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0
    func inc() -> Int { lock.lock(); defer { lock.unlock() }; v += 1; return v }
}
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock(); private var t: Date
    init(_ start: Date) { t = start }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
}

private func tempRoot() -> PersistenceRoot {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-rc21-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return PersistenceRoot(rootURL: dir)
}

private func runtime(with registry: CapabilityRegistry, device: FakeDeviceProfile, root: PersistenceRoot) async -> EshRuntime {
    let rt = EshRuntime(registry: InferenceBackendRegistry(backends: [:]), deviceProfileProvider: device)
    let ctx = ExecutionContext(root: root, artifactStore: FileArtifactStore(rootURL: root.artifactsURL))
    let svc = CapabilityExecutionService(registry: registry, context: ctx)
    await rt.attachCapabilities(service: svc, registry: registry, root: root)
    return rt
}

// MARK: - A: runtime resource state

@Suite struct RuntimeResourceFacadeTests {
    @Test func residentModelsFromRuntime() async {
        var reg = CapabilityRegistry()
        reg.register(MockResidentProvider(id: "pm", capability: .imageEdit, estimatedGB: 14, warm: true))
        reg.register(MockResidentProvider(id: "cold", capability: .imageGenerate, estimatedGB: 8, warm: false))
        let rt = await runtime(with: reg, device: FakeDeviceProfile(physical: UInt64(32 * GB), available: UInt64(20 * GB)), root: tempRoot())
        let resident = await rt.residentModels()
        #expect(resident.map(\.id) == ["pm"])
        #expect(resident.first?.estimatedPeakMemoryBytes == Int64(14 * GB))
        #expect(resident.first?.measuredMemoryBytes == nil)
    }

    @Test func resourcePressureReportsDeviceFacts() async {
        let root = tempRoot()
        let rt = await runtime(with: CapabilityRegistry(),
                               device: FakeDeviceProfile(physical: UInt64(32 * GB), available: UInt64(2 * GB)), root: root)
        let p = await rt.resourcePressure()
        #expect(p.totalMemoryBytes == Int64(32 * GB))
        #expect(p.availableMemoryBytes == Int64(2 * GB))
        #expect(p.memoryCritical)                       // 2 GB < floor (max 2GB / 10% = 3.2 GB)
        #expect(p.systemVolumeFreeBytes != nil)         // temp dir is on a real volume
    }

    @Test func resourcePressureNotCriticalWithHeadroom() async {
        let rt = await runtime(with: CapabilityRegistry(),
                               device: FakeDeviceProfile(physical: UInt64(32 * GB), available: UInt64(20 * GB)), root: tempRoot())
        let p = await rt.resourcePressure()
        #expect(!p.memoryCritical)
    }

    @Test func unloadIdleUnloadsWarmNotActive() async {
        var reg = CapabilityRegistry()
        let idle = MockResidentProvider(id: "idle", capability: .imageEdit, estimatedGB: 14, warm: true)
        let busy = MockResidentProvider(id: "busy", capability: .imageGenerate, estimatedGB: 8, warm: true, active: true)
        reg.register(idle); reg.register(busy)
        let rt = await runtime(with: reg, device: FakeDeviceProfile(physical: UInt64(32 * GB), available: nil), root: tempRoot())
        await rt.unloadIdleRuntimes()
        #expect(!idle.box.state.warm)   // idle released
        #expect(busy.box.state.warm)    // active untouched
    }

    @Test func explicitUnloadByIdAndTypedStates() async {
        var reg = CapabilityRegistry()
        let pm = MockResidentProvider(id: "pm", capability: .imageEdit, estimatedGB: 14, warm: true)
        let busy = MockResidentProvider(id: "busy", capability: .imageGenerate, estimatedGB: 8, warm: true, active: true)
        reg.register(pm); reg.register(busy)
        let rt = await runtime(with: reg, device: FakeDeviceProfile(physical: UInt64(32 * GB), available: nil), root: tempRoot())

        try? await rt.unload(modelID: "pm")
        #expect(!pm.box.state.warm)

        // Active model: refuse with a typed error, do not force.
        await #expect(throws: UnloadError.self) { try await rt.unload(modelID: "busy") }
        #expect(busy.box.state.warm)

        // Unknown id: typed error.
        await #expect(throws: UnloadError.self) { try await rt.unload(modelID: "nope") }
    }
}

// MARK: - B: download lifecycle

@Suite struct DownloadLifecycleTests {
    @Test func throughputAndETAFromRealSamples() {
        let clock = FakeClock(Date(timeIntervalSince1970: 0))
        let tracker = DownloadProgressTracker(expectedBytes: 1000, fileName: "m", clock: { clock.now() })
        _ = tracker.state(fraction: 0.25)     // first sample: 250 bytes, no bps yet
        clock.advance(1.0)
        let s = tracker.state(fraction: 0.5)  // +250 bytes over 1s → 250 B/s, 500 remaining → 2s ETA
        #expect(s.bytesDownloaded == 500)
        #expect(s.totalBytes == 1000)
        #expect(abs((s.bytesPerSecond ?? 0) - 250) < 1.0)
        #expect(abs((s.etaSeconds ?? 0) - 2.0) < 0.1)
        #expect(s.currentFile == "m")
        #expect(s.phase == .downloading)
    }

    @Test func richInstallProgressPhases() async {
        let install: ModelDownloadHandle.InstallRun = { onProgress in onProgress(0.5) }
        let handle = ModelDownloadHandle(id: "m", expectedBytes: 1000, install: install, discardPartial: {})
        await handle.start()
        var phases: [DownloadState.Phase] = []; var downloadingBytes: Int64 = -1
        do { for try await s in handle.events { phases.append(s.phase); if s.phase == .downloading { downloadingBytes = s.bytesDownloaded } } } catch {}
        #expect(phases.first == .resolving)
        #expect(phases.contains(.downloading))
        #expect(phases.last == .installed)
        #expect(downloadingBytes == 500)
    }

    @Test func pauseRetainsPartialThenResumeContinues() async {
        let discard = LockedBool()
        let runs = LockedInt()
        let install: ModelDownloadHandle.InstallRun = { onProgress in
            let run = runs.inc()
            onProgress(0.5)
            if run == 1 {
                // First run: block until paused (cancelled), retaining the partial (no discard).
                for _ in 0..<50_000_000 { try Task.checkCancellation(); await Task.yield() }
            } else {
                onProgress(1.0)   // resume run continues to completion
            }
        }
        let handle = ModelDownloadHandle(id: "m", expectedBytes: 1000, install: install,
                                         discardPartial: { discard.set(true) })
        await handle.start()
        var sawPaused = false, sawInstalled = false, pausedOnce = false
        do {
            for try await s in handle.events {
                if s.phase == .downloading, !pausedOnce { pausedOnce = true; await handle.pause() }
                else if s.phase == .paused { sawPaused = true; #expect(!discard.value); await handle.resume() }
                else if s.phase == .installed { sawInstalled = true }
            }
        } catch {}
        #expect(sawPaused)                 // pause surfaced
        #expect(!discard.value)            // partial retained across pause+resume
        #expect(sawInstalled)              // resume continued to completion
    }

    @Test func cancelTerminatesCleanlyAndDiscardsPartial() async {
        let discard = LockedBool()
        let install: ModelDownloadHandle.InstallRun = { onProgress in
            onProgress(0.5)
            for _ in 0..<50_000_000 { try Task.checkCancellation(); await Task.yield() }
        }
        let handle = ModelDownloadHandle(id: "m", expectedBytes: 1000, install: install,
                                         discardPartial: { discard.set(true) })
        await handle.start()
        var sawFailed = false, threw = false, cancelledOnce = false
        do {
            for try await s in handle.events {
                if s.phase == .downloading, !cancelledOnce { cancelledOnce = true; await handle.cancel() }
                if s.phase == .failed { sawFailed = true }
            }
        } catch is CancellationError { threw = true } catch {}
        #expect(threw)                     // stream terminated with a typed cancellation
        #expect(sawFailed)                 // a terminal state was surfaced
        #expect(discard.value)             // partial discarded (distinct from pause)
    }

    @Test func discardPartialIsSeparateFromRemoveAndSafe() async {
        let mgr = LocalModelManager(root: tempRoot())
        // Cancelling a download (discard partial) is distinct from removing an installed model, and is a
        // safe no-op when nothing partial is present. `remove()`/`isInstalled()` remain unchanged (covered by
        // LocalModelManagerTests + BackgroundDownloadTests).
        await mgr.discardPartialDownload("not-a-real-model")
        let installed = await mgr.isInstalled("not-a-real-model")
        #expect(installed == false)
    }
}
