import Foundation

public struct DownloadState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable, CaseIterable {
        case resolving
        case downloading
        case verifying
        case installed
        case failed
    }

    public var phase: Phase
    public var bytesDownloaded: Int64
    public var totalBytes: Int64?
    public var bytesPerSecond: Double?
    public var etaSeconds: Double?
    public var currentFile: String?
    public var message: String?

    public init(
        phase: Phase,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64? = nil,
        bytesPerSecond: Double? = nil,
        etaSeconds: Double? = nil,
        currentFile: String? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.etaSeconds = etaSeconds
        self.currentFile = currentFile
        self.message = message
    }
}
