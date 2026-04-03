import Foundation

public struct Stopwatch: Sendable {
    private let start = ContinuousClock.now

    public init() {}

    public func elapsedMilliseconds() -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
