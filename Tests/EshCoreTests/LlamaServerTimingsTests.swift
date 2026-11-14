import Foundation
import Testing
@testable import EshCore

@Suite struct LlamaServerTimingsTests {
    @Test func parsesFinalChunkTimingsIncludingSpeculation() throws {
        let chunk = #"{"choices":[{"delta":{}}],"timings":{"cache_n":12,"prompt_n":340,"prompt_ms":420.5,"prompt_per_second":808.5,"predicted_n":118,"predicted_per_second":16.9,"draft_n":64,"draft_n_accepted":51}}"#
        let t = try #require(LlamaServerTimings(chunkData: Data(chunk.utf8)))
        let m = t.applied(to: Metrics(ttftMilliseconds: 450))
        #expect(m.ttftMilliseconds == 450)
        #expect(m.promptTokens == 340)
        #expect(m.cachedTokens == 12)
        #expect(m.cacheHit == true)
        #expect(m.promptTokensPerSecond == 808.5)
        #expect(m.generationTokens == 118)
        #expect(m.tokensPerSecond == 16.9)
        #expect(m.draftTokens == 64)
        #expect(m.draftAcceptedTokens == 51)
    }

    @Test func chunksWithoutTimingsAreIgnored() {
        #expect(LlamaServerTimings(chunkData: Data(#"{"choices":[{"delta":{"content":"hi"}}]}"#.utf8)) == nil)
    }

    @Test func metricsStayDecodableWithoutTheNewFields() throws {
        let old = #"{"ttftMilliseconds":12,"tokensPerSecond":30}"#
        let m = try JSONDecoder().decode(Metrics.self, from: Data(old.utf8))
        #expect(m.tokensPerSecond == 30)
        #expect(m.promptTokensPerSecond == nil)
        #expect(m.residentCacheBytes == nil)
    }
}
