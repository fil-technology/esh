import Foundation
import Testing
import EshCore
@testable import esh

// UCMR Stage 3 — TTS is wired into the warm-pool / RAM-guard so a synthesis never over-commits unified
// memory on top of a resident LLM: keep the LLM warm when RAM is ample, evict idle LLMs under pressure,
// and refuse cleanly (never crash) when memory is still critically low.
@Suite
struct AudioSpeechMemoryGuardTests {
    @Test
    func plentifulMemoryDoesNotBlockOrRequireAPool() async throws {
        // Test hosts have GBs free, so the guard's fast path returns without a pool and without throwing.
        try await AudioSpeechGenerator.prepareMemoryForTTS(pool: nil)
    }

    @Test
    func memoryErrorExplainsHowToRecover() {
        let err = AudioSpeechGenerator.TTSMemoryError.insufficientMemory(availableMB: 300, neededMB: 800)
        let msg = err.errorDescription ?? ""
        #expect(msg.contains("300 MB free"))
        #expect(msg.contains("800 MB"))
        #expect(msg.lowercased().contains("unload a model"))
    }
}
