import Foundation

// rc.22 — deterministic per-variant seed derivation for multi-output executions. One base seed → N stable,
// well-distributed seeds. Index 0 returns the base unchanged, so a single-output request (or the first
// variant) reproduces exactly what the same base seed produced before this feature existed.
public enum VariantSeed {
    /// Deterministic seed for variant `index` from `base`. index 0 == base; index > 0 uses a splitmix64 mix
    /// so the variants are distinct + reproducible from the same base.
    public static func derive(base: UInt64, index: Int) -> UInt64 {
        guard index > 0 else { return base }
        var z = base &+ (UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// The full deterministic seed set for a batch of `count` outputs from `base`.
    public static func batch(base: UInt64, count: Int) -> [UInt64] {
        (0 ..< max(0, count)).map { derive(base: base, index: $0) }
    }
}
