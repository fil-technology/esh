import Foundation
import Darwin
import EshCore

enum DownloadProgressView {
    static func render(state: DownloadState) {
        let line = formattedLine(for: state)

        guard isatty(STDOUT_FILENO) != 0 else {
            print(line)
            return
        }

        Swift.print("\u{001B}[2K\r\(line)", terminator: "")
        fflush(stdout)

        if state.phase == .installed || state.phase == .failed {
            finish()
        }
    }

    static func finish() {
        guard isatty(STDOUT_FILENO) != 0 else { return }
        Swift.print("")
        fflush(stdout)
    }

    private static func formattedLine(for state: DownloadState) -> String {
        let downloaded = ByteFormatting.string(for: state.bytesDownloaded)
        let total = state.totalBytes.map(ByteFormatting.string(for:)) ?? "?"
        let speed = state.bytesPerSecond.map { ByteFormatting.string(for: Int64($0)) + "/s" } ?? "-"
        let eta = state.etaSeconds.map { String(format: "%.0fs", $0) } ?? "-"
        let file = state.currentFile ?? "-"
        let message = state.message ?? ""
        return "[\(state.phase.rawValue)] \(downloaded)/\(total) | \(speed) | eta \(eta) | \(file) | \(message)"
    }
}
