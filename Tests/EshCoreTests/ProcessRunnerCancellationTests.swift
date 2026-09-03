import Foundation
import Testing
@testable import EshCore

// esh 2.1 — cancellation invariant for long-running capability subprocesses (Stage 3, image.upscale). A
// user cancel must actually stop the helper process and reclaim resources — no orphan worker.
@Suite
struct ProcessRunnerCancellationTests {
    @Test
    func cancellableRunTerminatesTheSubprocessOnCancel() async throws {
        // Launch a 30s sleep in a cancellable run, cancel the surrounding Task shortly after, and assert it
        // returns promptly (killed) rather than blocking for 30s.
        let start = Date()
        let task = Task { () -> Bool in
            do {
                _ = try ProcessRunner.runCancellable(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
                return false   // completed normally → NOT cancelled (unexpected)
            } catch is CancellationError {
                return true    // terminated via cancellation (expected)
            } catch {
                return false
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)   // let it start
        task.cancel()
        let cancelled = await task.value
        let elapsed = Date().timeIntervalSince(start)
        #expect(cancelled)              // threw CancellationError
        #expect(elapsed < 5.0)          // stopped promptly, not after the full 30s sleep
    }

    @Test
    func nonCancellableRunStillCompletesNormally() throws {
        // Regression guard: the plain run() path is unchanged (a short process completes and returns output).
        let out = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["ok"])
        #expect(out.exitCode == 0)
        #expect(String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }
}
