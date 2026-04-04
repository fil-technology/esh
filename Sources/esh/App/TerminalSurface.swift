import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class TerminalSurface {
    private let clearScreen = "\u{001B}[2J\u{001B}[H"
    private var lastLines: [String] = []
    private var lastSize: (rows: Int, columns: Int)?

    func render(state: ChatScreenState) {
        let size = terminalSize()
        let overlayLines = state.overlay.map {
            OverlayPanelView.renderedLines(overlay: $0, availableWidth: size.columns)
        } ?? []
        let reservedBottom = 2 + overlayLines.count
        let transcriptHeight = max(size.rows - reservedBottom, 1)

        let transcriptLines = TranscriptView.renderedLines(
            items: state.transcriptItems,
            availableWidth: size.columns
        )
        let visibleTranscript = Array(transcriptLines.suffix(transcriptHeight))

        var output: [String] = []
        output.reserveCapacity(size.rows)
        output.append(contentsOf: visibleTranscript)

        if visibleTranscript.count < transcriptHeight {
            output.append(contentsOf: Array(repeating: "", count: transcriptHeight - visibleTranscript.count))
        }

        output.append(contentsOf: overlayLines)
        let inputLine = InputBarView.render(state: state, width: size.columns)
        output.append(inputLine)
        output.append(FooterStatsView.renderedLine(state: state, width: size.columns))

        var commands = ""
        let needsFullRedraw =
            lastSize?.rows != size.rows ||
            lastSize?.columns != size.columns ||
            lastLines.count != output.count

        if needsFullRedraw {
            commands += clearScreen
            for (index, line) in output.enumerated() {
                commands += "\u{001B}[\(index + 1);1H\u{001B}[2K\(line)"
            }
        } else {
            for (index, line) in output.enumerated() where line != lastLines[index] {
                commands += "\u{001B}[\(index + 1);1H\u{001B}[2K\(line)"
            }
        }

        let cursorOffset = min(max(inputLine.count, 0), max(size.columns - 1, 0))
        let inputRow = max(output.count - 1, 1)
        commands += "\u{001B}[\(inputRow);1H\u{001B}[\(cursorOffset)C"
        Swift.print(commands, terminator: "")
        fflush(stdout)
        lastLines = output
        lastSize = size
    }

    private func terminalSize() -> (rows: Int, columns: Int) {
        #if canImport(Darwin)
        var windowSize = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize) == 0,
           windowSize.ws_row > 0,
           windowSize.ws_col > 0 {
            return (Int(windowSize.ws_row), Int(windowSize.ws_col))
        }
        #endif

        let environment = ProcessInfo.processInfo.environment
        let rows = Int(environment["LINES"] ?? "") ?? 24
        let columns = Int(environment["COLUMNS"] ?? "") ?? 100
        return (rows, columns)
    }
}
