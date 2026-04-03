import Foundation
import Testing
@testable import LLMCacheCore

@Test
func mlxCodecRoundTripsSnapshot() throws {
    let codec = MLXCacheSnapshotCodec()
    let snapshot = CacheSnapshot(
        format: "mlx",
        metadata: ["model": "demo"],
        tensors: [.init(name: "layer0.keys", shape: [1, 1, 1, 3], dtype: "float32", data: Data("abc".utf8))]
    )

    let data = try codec.encode(snapshot: snapshot)
    let decoded = try codec.decode(data: data)

    #expect(decoded == snapshot)
}
