import Foundation

public struct ModelInstall: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var spec: ModelSpec
    public var installPath: String
    public var sizeBytes: Int64
    public var installedAt: Date
    public var backendFormat: String
    public var runtimeVersion: String?

    public init(
        id: String,
        spec: ModelSpec,
        installPath: String,
        sizeBytes: Int64,
        installedAt: Date = Date(),
        backendFormat: String,
        runtimeVersion: String? = nil
    ) {
        self.id = id
        self.spec = spec
        self.installPath = installPath
        self.sizeBytes = sizeBytes
        self.installedAt = installedAt
        self.backendFormat = backendFormat
        self.runtimeVersion = runtimeVersion
    }
}
