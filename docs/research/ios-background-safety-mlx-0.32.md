# iOS background safety on mlx-swift 0.32.x — the bg-safety patch is obsolete

**Status of iOS background safety: PENDING DEVICE VALIDATION (not verified).** The code-level crash mode
below is structurally resolved upstream in mlx-swift 0.32.x; this has NOT been confirmed on a physical iOS
device. macOS Studio integration does not depend on this and is not blocked by it.

## 1. The original iOS background crash (why the fork patch existed)

On mlx-swift ≤ 0.31.x, `mlx/backend/metal/eval.cpp` checked command-buffer completion like this:

```cpp
inline void check_error(MTL::CommandBuffer* cbuf) {
  if (cbuf->status() == MTL::CommandBufferStatusError) {
    throw std::runtime_error("[METAL] Command buffer execution failed: " + ...);
  }
}
// ... attached as a Metal completion handler:
command_buffer->addCompletedHandler([...](MTL::CommandBuffer* cbuf) { check_error(cbuf); });
```

iOS revokes GPU access when the host app transitions to the background. Metal still fires completion
handlers for buffers that were already submitted when the clamp landed, with
`CommandBufferStatusError` and a `"submit GPU work from background"` description. `check_error` then
**`throw`s from Metal's completion-handler thread** — a thread no Swift `try/catch` can reach — so the
C++ exception is uncaught and **terminates the process**.

The `fil-technology/mlx` fork added commit `6525ede` ("check_error: swallow iOS background-permission
errors"), consumed via the `fil-technology/mlx-swift` tag `0.31.3-tts-bg-safe.1`. It special-cased that one
error description and swallowed it (logging instead of throwing), so backgrounding mid-flight did not crash.

## 2. The upstream implementation change (mlx 0.32.x)

mlx 0.32.x (submodule `v0.32.2`, in mlx-swift 0.32.3) **removed `check_error` entirely** and refactored the
Metal command path into a `CommandEncoder` with a stored-error model
(`mlx/backend/metal/device.cpp`):

- The completion handler attached in `CommandEncoder::commit(...)` **no longer throws**. On
  `CommandBufferStatusError` it **stores** the message into an `error_` holder
  (`error_.set_message(...)`) and signals events — all on the Metal callback thread, without throwing.
- The stored error is surfaced later by `error_.check()` (which throws if an error was recorded), called on
  the **calling thread** — `CommandEncoder::synchronize()` and `get_command_encoder()` — i.e. a thread the
  Swift layer can `try/catch`.
- Teardown is guarded: `synchronize()` runs `if (!exiting_) error_.check();`, so it does not throw during
  process exit.

## 3. Why the patch is no longer necessary

The patch's entire purpose was to prevent a `throw` **from the Metal completion-handler thread**. In 0.32.x
that `throw` does not exist: the handler stores, it does not throw, and the only throw happens on the
calling thread (Swift-reachable) via `error_.check()`. The specific uncaught-exception-from-callback-thread
process termination is therefore **structurally gone upstream**, independent of any fork patch. Porting the
old swallow would modify code that can no longer crash the way it used to.

**Decision:** reference upstream `ml-explore/mlx-swift` `0.32.3` directly. No `fil-technology/mlx-swift`
fork, no patch port. (Bonus: all consumers reference the same `ml-explore/mlx-swift` URL, so the previous
"Conflicting identity for mlx-swift" SwiftPM warnings disappear.)

## 4. iOS background/foreground lifecycle regression test plan (PENDING a physical device)

These require a real iOS device (background GPU clamping is not reproducible in the Simulator or on macOS).
Mark each PENDING until run on-device; none gate macOS integration.

1. **GPU inference across suspension:** start a multi-second MLX inference (e.g. a VLM or image diffusion),
   send the app to the background mid-inference (home gesture / `UIApplication` background), and assert the
   process does **not** terminate. Expect either a clean cancel or a Swift-catchable error surfaced on the
   calling thread — never an uncaught C++ exception.
2. **Resumption:** foreground the app and run a fresh inference; assert it completes correctly (GPU access
   re-acquired, no stuck encoder/residency state).
3. **Metal command-buffer failure surfacing:** force/observe a `CommandBufferStatusError` while backgrounded
   and assert it arrives via a thrown Swift error from the `synchronize()`/calling-thread path (catchable),
   not as a crash.
4. **Repeated lifecycle transitions:** background→foreground 10+ times with inferences interleaved; assert no
   leak, no crash, stable memory, and that cancellation on each background is prompt.
5. **Exit during in-flight work:** terminate the app while a command buffer is in flight; assert clean
   teardown (the `exiting_` guard skips `error_.check()`), no abort at `__cxa_finalize`.
6. **Regression harness:** add an iOS XCUITest (or a device unit test driving `EshRuntime` + a lifecycle
   mock) wired into the device CI lane; until that runs, iOS background safety is **pending device
   validation, not verified**.
