import Foundation

/// Portable helpers for reading typed values out of a capability request's options bag.
/// Extracted from `VideoUnderstandingProvider` (esh iOS M1) so portable providers (web/project/SVG
/// generation) can parse request options without depending on the macOS-only video provider.
public enum CapabilityRequestOptions {
    /// The string value for `key` in `req.options`, or nil when absent or not a string.
    public static func string(_ req: ExecutionRequest, _ key: String) -> String? {
        if case .string(let s)? = req.options.values[key] { return s }
        return nil
    }
}
