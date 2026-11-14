#if os(macOS)
// macOS only: the MLX text backend drives a Python bridge through `Process` (one-shot subprocess or persistent
// worker), which iOS does not allow. On iOS this module provides only an unavailable `MLXBackend` (see MLXBackendUnavailable.swift).
import Foundation
import EshCore

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
