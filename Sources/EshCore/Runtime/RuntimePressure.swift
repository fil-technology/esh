import Foundation

/// A runtime-pressure signal the model lifecycle can react to (release caches, unload an idle runtime,
/// pick a smaller model). The smallest useful seam for future mobile model management — deliberately not a
/// full eviction policy.
public enum RuntimePressureEvent: Sendable, Equatable {
    case memoryWarning
    case memoryCritical
    case thermalStateChanged(ThermalState)
    case lowPowerModeChanged(Bool)
}

/// A source of runtime-pressure events. Injectable so lifecycle logic and tests can drive pressure
/// deterministically.
public protocol RuntimePressureSource: Sendable {
    /// A stream of pressure events for the lifetime of the returned stream.
    func events() -> AsyncStream<RuntimePressureEvent>
}

/// System-backed pressure source: memory pressure via `DispatchSource` (works on iOS and macOS, no UIKit),
/// thermal changes via `ProcessInfo.thermalStateDidChangeNotification`, and Low Power Mode via
/// `NSProcessInfoPowerStateDidChange`. All observers are torn down when the stream terminates.
public struct SystemRuntimePressureSource: RuntimePressureSource {
    public init() {}

    /// Holds the non-Sendable observer tokens + dispatch source so the `@Sendable` termination handler can
    /// tear them down without capturing them directly (Swift 6 strict concurrency).
    private final class Subscriptions: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        var memory: DispatchSourceMemoryPressure?
        func tearDown() {
            memory?.cancel()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens.removeAll()
        }
    }

    public func events() -> AsyncStream<RuntimePressureEvent> {
        AsyncStream { continuation in
            let subs = Subscriptions()
            let queue = DispatchQueue(label: "esh.runtime-pressure")
            let mem = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
            mem.setEventHandler {
                let data = mem.data
                if data.contains(.critical) { continuation.yield(.memoryCritical) }
                else if data.contains(.warning) { continuation.yield(.memoryWarning) }
            }
            mem.resume()
            subs.memory = mem

            let center = NotificationCenter.default
            subs.tokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
                if let s = SystemDeviceProfileProvider.map(ProcessInfo.processInfo.thermalState) {
                    continuation.yield(.thermalStateChanged(s))
                }
            })
            subs.tokens.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
                continuation.yield(.lowPowerModeChanged(ProcessInfo.processInfo.isLowPowerModeEnabled))
            })

            continuation.onTermination = { _ in subs.tearDown() }
        }
    }
}
