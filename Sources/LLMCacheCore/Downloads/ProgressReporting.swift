import Foundation

public protocol ProgressReporting: Sendable {
    func emit(_ state: DownloadState)
}

public struct ClosureProgressReporter: ProgressReporting, Sendable {
    private let callback: @Sendable (DownloadState) -> Void

    public init(callback: @escaping @Sendable (DownloadState) -> Void) {
        self.callback = callback
    }

    public func emit(_ state: DownloadState) {
        callback(state)
    }
}
