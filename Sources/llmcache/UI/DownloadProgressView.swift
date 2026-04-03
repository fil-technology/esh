import Foundation
import LLMCacheCore

enum DownloadProgressView {
    static func render(state: DownloadState) {
        let downloaded = ByteFormatting.string(for: state.bytesDownloaded)
        let total = state.totalBytes.map(ByteFormatting.string(for:)) ?? "?"
        let speed = state.bytesPerSecond.map { ByteFormatting.string(for: Int64($0)) + "/s" } ?? "-"
        let eta = state.etaSeconds.map { String(format: "%.0fs", $0) } ?? "-"
        let file = state.currentFile ?? "-"
        print("[\(state.phase.rawValue)] \(downloaded)/\(total) | \(speed) | eta \(eta) | \(file) | \(state.message ?? "")")
    }
}
