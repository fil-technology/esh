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
        // `cancelled == true` is the real invariant: runCancellable only throws CancellationError AFTER it has
        // terminated the subprocess (SIGTERM → grace → SIGKILL), so this proves the process was actually killed.
        #expect(cancelled)
        // Guard against blocking for the whole 30s sleep. The bound is deliberately loose (not "instant"):
        // cancellation is observed via a 50ms poll on a cooperative thread, and a loaded CI runner adds real
        // scheduling latency (observed ~11s vs ~3s locally). 20s still proves "killed, not run to completion".
        #expect(elapsed < 20.0)
    }

    @Test
    func nonCancellableRunStillCompletesNormally() throws {
        // Regression guard: the plain run() path is unchanged (a short process completes and returns output).
        let out = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["ok"])
        #expect(out.exitCode == 0)
        #expect(String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }
}
