import Testing
@testable import esh

@Suite
struct TerminalSurfaceTests {
    @Test
    func visibleTranscriptLinesFollowBottomByDefault() {
        let lines = (1...8).map { "line-\($0)" }

        let visible = TerminalSurface.visibleTranscriptLines(
            transcriptLines: lines,
            transcriptHeight: 3,
            scrollOffset: 0
        )

        #expect(visible == ["line-6", "line-7", "line-8"])
    }

    @Test
    func visibleTranscriptLinesScrollBackFromBottom() {
        let lines = (1...8).map { "line-\($0)" }

        let visible = TerminalSurface.visibleTranscriptLines(
            transcriptLines: lines,
            transcriptHeight: 3,
            scrollOffset: 2
        )

        #expect(visible == ["line-4", "line-5", "line-6"])
    }

    @Test
    func visibleTranscriptLinesClampLargeOffsets() {
        let lines = (1...5).map { "line-\($0)" }

        let visible = TerminalSurface.visibleTranscriptLines(
            transcriptLines: lines,
            transcriptHeight: 2,
            scrollOffset: 99
        )

        #expect(visible == ["line-1", "line-2"])
    }
}
