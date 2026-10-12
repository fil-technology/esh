import Testing
import EshCore
@testable import EshMLXText

/// Regression: the MLX text backend is remote-consumable from the root package, exposes the
/// `.mlx` backend kind, and is constructible without a running worker (lifecycle is esh's).
struct EshMLXTextTests {
    @Test func mlxBackendIsConstructibleAndReportsMLXKind() {
        let backend = MLXBackend()
        #expect(backend.kind == .mlx)
    }
}
