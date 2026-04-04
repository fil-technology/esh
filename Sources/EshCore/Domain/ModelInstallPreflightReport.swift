import Foundation

public struct ModelInstallPreflightReport: Sendable {
    public var notes: [String]
    public var warnings: [String]
    public var blockers: [String]

    public init(
        notes: [String] = [],
        warnings: [String] = [],
        blockers: [String] = []
    ) {
        self.notes = notes
        self.warnings = warnings
        self.blockers = blockers
    }

    public var isBlocked: Bool {
        !blockers.isEmpty
    }
}
