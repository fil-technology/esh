import Foundation
import EshCore
import EshRuntime

/// Adapts one compatibility engine (manifest + host) to the public `CapabilityProvider` facade. It owns the
/// preflight → install/repair → execute state machine, forwards the host's events, maps failures to typed
/// `CompatibilityError`s (never a raw traceback), and reports honest availability into discovery. The same
/// public `execute`/`stream` contract as every native provider — the consumer sees no difference.
public final class CompatibilityCapabilityProvider: CapabilityProvider, CapabilityAvailabilityRefreshing, @unchecked Sendable {
    public let descriptor: CapabilityProviderDescriptor
    private let manifest: CompatibilityEngineManifest
    private let host: CompatibilityEngineHost
    private let stateBox: StateBox
    /// When false (non-macOS), the engine is inert and reports `.unsupportedOnPlatform`.
    private let supported: Bool

    public init(manifest: CompatibilityEngineManifest, host: CompatibilityEngineHost, supported: Bool) {
        self.manifest = manifest
        self.host = host
        self.supported = supported
        self.stateBox = StateBox(supported ? .notInstalled : .unsupportedOnPlatform)
        self.descriptor = CapabilityProviderDescriptor(
            id: "compat-\(manifest.id.rawValue)",
            capabilities: manifest.capabilities,
            acceptedInputs: manifest.acceptedInputs,
            producedOutputs: manifest.producedOutputs,
            backend: .python, streaming: true, structuredOutput: false,
            requiredPrivilege: .artifactOnly, previewMode: .none)
    }

    /// Refresh cached availability from a live preflight (call off the hot path, e.g. at discovery time).
    public func refresh() async {
        guard supported else { return }
        stateBox.set(await host.inspect(manifest))
    }

    // CapabilityAvailabilityRefreshing
    public func refreshAvailability() async { await refresh() }

    // MARK: CapabilityAvailabilityReporting
    public func reportedAvailability(for capability: CapabilityID) -> CapabilityAvailability? {
        guard descriptor.capabilities.contains(capability) else { return nil }
        return stateBox.get().availability
    }

    // MARK: CapabilityProvider
    public func execute(_ request: ResolvedExecutionRequest,
                        context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let manifest = self.manifest
        let host = self.host
        let stateBox = self.stateBox
        let supported = self.supported
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard supported else {
                    stateBox.set(.unsupportedOnPlatform)
                    continuation.yield(.failed(message: CompatibilityError.unsupportedOnPlatform.errorDescription ?? "unsupported"))
                    continuation.finish(); return
                }
                do {
                    // Resource preflight (defense-in-depth with scripts/compat-preflight.sh): refuse to run
                    // when the internal volume lacks the swap headroom this model needs. Honest, typed, and
                    // non-crashing — the 2026-09-16 watchdog panic came from letting a heavy run proceed into
                    // swap exhaustion on a near-full disk. Freeing disk restores availability.
                    let internalFree = SystemStorage.snapshot(at: context.root.stateRootURL)?.availableBytes
                    if let reason = Self.insufficientResourceReason(internalFreeBytes: internalFree, manifest: manifest) {
                        stateBox.set(.insufficientResources(reason: reason))
                        continuation.yield(.failed(message: CompatibilityError.insufficientResources(reason: reason).errorDescription ?? "insufficient resources"))
                        continuation.finish(); return
                    }
                    continuation.yield(.status("checking \(manifest.id.rawValue) engine"))
                    // Preflight → install/repair as needed, updating cached state honestly.
                    var state = await host.inspect(manifest); stateBox.set(state)
                    if case .ready = state {} else {
                        switch state {
                        case .notInstalled, .requiresDownload:
                            stateBox.set(.installing(progress: 0))
                            continuation.yield(.status("installing \(manifest.id.rawValue) engine"))
                            try await host.install(manifest) { p in
                                stateBox.set(.installing(progress: p)); continuation.yield(.progress(p))
                            }
                        case .repairRequired(let reason):
                            continuation.yield(.status("repairing \(manifest.id.rawValue) engine (\(reason))"))
                            try await host.repair(manifest)
                        case .unsupportedOnPlatform:
                            throw CompatibilityError.unsupportedOnPlatform
                        case .failed(let r):
                            throw CompatibilityError.executionFailed(reason: r)
                        case .insufficientResources(let r):
                            throw CompatibilityError.insufficientResources(reason: r)
                        case .installing, .ready:
                            break
                        }
                        state = await host.inspect(manifest); stateBox.set(state)
                        guard case .ready = state else { throw Self.notReadyError(manifest.id, state) }
                    }
                    try Task.checkCancellation()
                    // Execute — forward the host's events verbatim (status/progress/artifactProduced/…).
                    for try await event in host.run(manifest, request, context: context) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let e as CompatibilityError {
                    continuation.yield(.failed(message: e.errorDescription ?? "failed"))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(message: CompatibilityError.executionFailed(reason: error.localizedDescription).errorDescription ?? "failed"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload() async {}

    /// Baseline free-disk floor for any generative compat engine (swap headroom). Heavier models require
    /// more via the size-scaled term in `insufficientResourceReason`.
    static let baseSwapHeadroomBytes: Int64 = 8 * 1024 * 1024 * 1024  // 8 GiB

    /// Pure resource-preflight decision (unit-testable): the honest reason a run must be refused right now,
    /// or nil to proceed. Required internal headroom = max(base floor, 2× declared model footprint). Never
    /// blocks when free space is unknown (nil) — honesty over false negatives.
    static func insufficientResourceReason(internalFreeBytes: Int64?, manifest: CompatibilityEngineManifest) -> String? {
        guard let free = internalFreeBytes else { return nil }
        let modelBytes = manifest.approxDownloadBytes ?? 0
        let required = max(baseSwapHeadroomBytes, modelBytes * 2)
        guard free < required else { return nil }
        let gib: (Int64) -> Double = { Double($0) / 1_073_741_824 }
        return String(format: "only %.1f GiB free on the internal volume; ~%.0f GiB needed as swap headroom for %@ (free disk and retry)",
                      gib(free), gib(required), manifest.id.rawValue)
    }

    private static func notReadyError(_ id: CompatibilityEngineID, _ state: CompatibilityEngineState) -> CompatibilityError {
        switch state {
        case .repairRequired(let r): return .engineRepairRequired(id, reason: r)
        case .notInstalled, .requiresDownload: return .engineNotInstalled(id)
        case .failed(let r): return .executionFailed(reason: r)
        case .unsupportedOnPlatform: return .unsupportedOnPlatform
        default: return .runtimeUnavailable(reason: "engine did not reach a ready state")
        }
    }

    /// Thread-safe cached-state holder so `reportedAvailability` stays synchronous for discovery.
    final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CompatibilityEngineState
        init(_ initial: CompatibilityEngineState) { value = initial }
        func get() -> CompatibilityEngineState { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: CompatibilityEngineState) { lock.lock(); value = newValue; lock.unlock() }
    }
}
