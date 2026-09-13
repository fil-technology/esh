#if os(macOS)   // esh iOS M1: macOS-only execution layer (subprocess/Python/llama-server); excluded from iOS builds. See docs/IOS_PORTABILITY_AUDIT.md.
import Foundation

public struct MLXModelLocator: Sendable {
    public init() {}

    public func resolveModelPath(for install: ModelInstall) throws -> URL {
        let url = URL(fileURLWithPath: install.installPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound("Model install path does not exist: \(install.installPath)")
        }
        return url
    }
}

#endif
