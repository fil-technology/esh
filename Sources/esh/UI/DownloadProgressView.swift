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
        let phase = padded(state.phase.rawValue.lowercased(), width: 12)
        let totalBytes = max(state.totalBytes ?? 0, 0)
        let currentFileDownloaded = max(state.currentFileBytesDownloaded ?? state.bytesDownloaded, 0)
        let currentFileTotal = max(state.currentFileTotalBytes ?? 0, 0)
        let ratio: Double?
        if totalBytes > 0 {
            ratio = min(max(Double(state.bytesDownloaded) / Double(totalBytes), 0), 1)
        } else if currentFileTotal > 0 {
            ratio = min(max(Double(currentFileDownloaded) / Double(currentFileTotal), 0), 1)
        } else {
            ratio = nil
        }
        let bar = progressBar(progress: ratio, width: 24, downloadedBytes: state.bytesDownloaded)
        let percent = ratio.map { String(format: "%3.0f%%", $0 * 100) } ?? " --%"
        let fileTransferred = padded(ByteFormatting.string(for: currentFileDownloaded), width: 8, alignRight: true)
        let fileTotal = padded(state.currentFileTotalBytes.map(ByteFormatting.string(for:)) ?? "?", width: 8, alignRight: true)
        let modelSummary = padded(modelSizeSummary(for: state), width: 20)
        let speed = padded(state.bytesPerSecond.map { ByteFormatting.string(for: Int64($0)) + "/s" } ?? "-", width: 10, alignRight: true)
        let eta = padded(state.etaSeconds.map(formatETA(_:)) ?? "-", width: 6, alignRight: true)
        let file = truncateMiddle(state.currentFile ?? state.message ?? "model", limit: 28)
        return "\(TerminalUIStyle.slate)\(phase)\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(file)\(TerminalUIStyle.reset)  \(percent) \(bar)  \(fileTransferred)/\(fileTotal)  \(modelSummary)  \(speed)  \(eta)"
    }

    private static func progressBar(progress: Double?, width: Int, downloadedBytes: Int64) -> String {
        if let progress {
            let filled = Int((progress * Double(width)).rounded(.down))
            let safeFilled = min(max(filled, 0), width)
            return String(repeating: "█", count: safeFilled) + String(repeating: "░", count: width - safeFilled)
        }

        var cells = Array(repeating: Character("░"), count: width)
        let pulseWidth = min(6, width)
        let offset = Int((downloadedBytes / 65_536) % Int64(max(width - pulseWidth + 1, 1)))
        for index in offset..<(offset + pulseWidth) where cells.indices.contains(index) {
            cells[index] = Character("█")
        }
        return String(cells)
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

    private static func formatETA(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        if value >= 60 {
            return String(format: "%dm%02ds", value / 60, value % 60)
        }
        return "\(value)s"
    }

    private static func modelSizeSummary(for state: DownloadState) -> String {
        let modelDownloaded = ByteFormatting.string(for: state.bytesDownloaded)
        if let totalBytes = state.totalBytes {
            return "model \(modelDownloaded)/\(ByteFormatting.string(for: totalBytes))"
        }
        return "model \(modelDownloaded)"
    }
}
