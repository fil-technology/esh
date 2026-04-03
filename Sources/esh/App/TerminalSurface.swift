import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct TerminalSurface {
    private let clearScreen = "\u{001B}[2J\u{001B}[H"

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
        output.append(InputBarView.render(state: state, width: size.columns))
        output.append(FooterStatsView.renderedLine(state: state, width: size.columns))

        let cursorToInputBar = "\u{001B}[1A\r\u{001B}[2C"
        Swift.print(clearScreen + output.joined(separator: "\n") + cursorToInputBar, terminator: "")
        fflush(stdout)
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
