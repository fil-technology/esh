import Foundation
import EshCore
#if canImport(Darwin)
import Darwin
#endif

final class TerminalSurface {
    private let clearScreen = "\u{001B}[2J\u{001B}[H"
    private var lastLines: [String] = []
    private var lastSize: (rows: Int, columns: Int)?

    func render(state: ChatScreenState) {
        let size = terminalSize()
        let headerLines = HeaderBarView.renderedLines(state: state, width: size.columns)
        let overlayLines = state.overlay.map {
            OverlayPanelView.renderedLines(overlay: $0, availableWidth: size.columns)
        } ?? []
        let suggestionLines = Self.slashSuggestionLines(input: state.inputText, width: size.columns)
        let reservedBottom = 2 + overlayLines.count + suggestionLines.count
        let reservedTop = headerLines.count + 1
        let transcriptHeight = max(size.rows - reservedBottom - reservedTop, 1)

        let transcriptLines = TranscriptView.renderedLines(
            items: state.transcriptItems,
            availableWidth: max(size.columns - 4, 20),
            reasoningExpanded: state.reasoningExpanded
        )
        let visibleTranscript = Self.visibleTranscriptLines(
            transcriptLines: transcriptLines,
            transcriptHeight: transcriptHeight,
            scrollOffset: state.transcriptScrollOffset
        )

        var output: [String] = []
        output.reserveCapacity(size.rows)
        output.append(contentsOf: headerLines)
        output.append(TerminalUIStyle.rule(width: size.columns))
        output.append(contentsOf: visibleTranscript.map { "  " + $0 })

        if visibleTranscript.count < transcriptHeight {
            output.append(contentsOf: Array(repeating: "", count: transcriptHeight - visibleTranscript.count))
        }

        output.append(contentsOf: overlayLines)
        output.append(contentsOf: suggestionLines)
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

        let cursorOffset = min(max(TerminalUIStyle.visibleWidth(of: inputLine), 0), max(size.columns - 1, 0))
        let inputRow = max(output.count - 1, 1)
        commands += "\u{001B}[\(inputRow);1H\u{001B}[\(cursorOffset)C"
        Swift.print(commands, terminator: "")
        fflush(stdout)
        lastLines = output
        lastSize = size
    }

    /// Slash-command autocomplete lines shown above the input as the user types `/…`.
    static func slashSuggestionLines(input: String, width: Int) -> [String] {
        let suggestions = SlashCommandCatalog.suggestions(for: input)
        guard !suggestions.isEmpty else { return [] }
        var lines: [String] = ["\(TerminalUIStyle.faint)commands (\(suggestions.count)) — Tab/Enter to run:\(TerminalUIStyle.reset)"]
        for entry in suggestions {
            let left = "\(TerminalUIStyle.cyan)\(entry.display)\(TerminalUIStyle.reset)"
            let line = "  \(left)  \(TerminalUIStyle.faint)\(entry.description)\(TerminalUIStyle.reset)"
            lines.append(TerminalUIStyle.truncateVisible(line, limit: width))
        }
        return lines
    }

    static func visibleTranscriptLines(
        transcriptLines: [String],
        transcriptHeight: Int,
        scrollOffset: Int
    ) -> [String] {
        guard transcriptHeight > 0 else { return [] }
        guard transcriptLines.count > transcriptHeight else { return transcriptLines }

        let maxOffset = max(transcriptLines.count - transcriptHeight, 0)
        let clampedOffset = min(max(scrollOffset, 0), maxOffset)
        let endIndex = max(transcriptLines.count - clampedOffset, 0)
        let startIndex = max(endIndex - transcriptHeight, 0)
        return Array(transcriptLines[startIndex..<endIndex])
    }

    static func maxTranscriptScrollOffset(
        state: ChatScreenState,
        terminalRows: Int,
        terminalColumns: Int
    ) -> Int {
        let headerLines = HeaderBarView.renderedLines(state: state, width: terminalColumns)
        let overlayLines = state.overlay.map {
            OverlayPanelView.renderedLines(overlay: $0, availableWidth: terminalColumns)
        } ?? []
        let reservedBottom = 2 + overlayLines.count
        let reservedTop = headerLines.count + 1
        let transcriptHeight = max(terminalRows - reservedBottom - reservedTop, 1)
        let transcriptLines = TranscriptView.renderedLines(
            items: state.transcriptItems,
            availableWidth: max(terminalColumns - 4, 20),
            reasoningExpanded: state.reasoningExpanded
        )
        return max(transcriptLines.count - transcriptHeight, 0)
    }

    func maxTranscriptScrollOffset(state: ChatScreenState) -> Int {
        let size = terminalSize()
        return Self.maxTranscriptScrollOffset(
            state: state,
            terminalRows: size.rows,
            terminalColumns: size.columns
        )
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
