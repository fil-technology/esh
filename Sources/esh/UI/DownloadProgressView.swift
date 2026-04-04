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
        let phase = padded("[\(state.phase.rawValue)]", width: 13)
        let totalBytes = max(state.totalBytes ?? 0, 0)
        let ratio = totalBytes > 0 ? min(max(Double(state.bytesDownloaded) / Double(totalBytes), 0), 1) : nil
        let bar = progressBar(progress: ratio, width: 18, downloadedBytes: state.bytesDownloaded)
        let percent = ratio.map { String(format: "%5.1f%%", $0 * 100) } ?? "  -- %"
        let downloaded = padded(ByteFormatting.string(for: state.bytesDownloaded), width: 9, alignRight: true)
        let total = padded(state.totalBytes.map(ByteFormatting.string(for:)) ?? "?", width: 9, alignRight: true)
        let speed = padded(state.bytesPerSecond.map { ByteFormatting.string(for: Int64($0)) + "/s" } ?? "-", width: 10, alignRight: true)
        let eta = padded(state.etaSeconds.map { String(format: "%.0fs", $0) } ?? "-", width: 5, alignRight: true)
        let file = truncateMiddle(state.currentFile ?? "-", limit: 26)
        let message = state.message ?? ""
        return "\(phase) \(bar) \(percent)  \(downloaded)/\(total)  \(speed)  eta \(eta)  \(file)  \(message)"
    }

    private static func progressBar(progress: Double?, width: Int, downloadedBytes: Int64) -> String {
        if let progress {
            let filled = Int((progress * Double(width)).rounded(.down))
            let safeFilled = min(max(filled, 0), width)
            return "[" + String(repeating: "=", count: safeFilled) + String(repeating: "-", count: width - safeFilled) + "]"
        }

        var cells = Array(repeating: Character("-"), count: width)
        let pulseWidth = min(5, width)
        let offset = Int((downloadedBytes / 65_536) % Int64(max(width - pulseWidth + 1, 1)))
        for index in offset..<(offset + pulseWidth) where cells.indices.contains(index) {
            cells[index] = Character("=")
        }
        return "[" + String(cells) + "]"
    }

    private static func padded(_ value: String, width: Int, alignRight: Bool = false) -> String {
        guard value.count < width else { return value }
        let padding = String(repeating: " ", count: width - value.count)
        return alignRight ? padding + value : value + padding
    }

    private static func truncateMiddle(_ value: String, limit: Int) -> String {
        guard value.count > limit, limit > 3 else { return value }
        let prefixCount = max((limit - 1) / 2, 1)
        let suffixCount = max(limit - prefixCount - 1, 1)
        let start = String(value.prefix(prefixCount))
        let end = String(value.suffix(suffixCount))
        return start + "…" + end
    }
}
