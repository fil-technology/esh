import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resolves the absolute path of the running executable via the OS, not `CommandLine.arguments[0]`.
///
/// `argv[0]` is whatever the caller passed to `exec` — under a PATH/shim invocation (the normal
/// `esh …` Homebrew case) it is often the bare command name, which resolves against the *current
/// working directory* rather than the real binary location. Relying on it made packaged-runtime
/// discovery (the bundled MLX bridge, `VERSION`, llama-cli) silently fail, falling back to a path
/// baked in at build time. `_NSGetExecutablePath` returns the true image path regardless of how the
/// process was launched.
public enum ExecutablePath {
    /// Absolute, symlink-resolved URL of the running executable. Falls back to `argv[0]` only if the
    /// OS call is unavailable or fails.
    public static func resolvedURL() -> URL {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer)
                if !path.isEmpty {
                    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
                }
            }
        }
        #endif
        let argv0 = CommandLine.arguments.first ?? ""
        return URL(fileURLWithPath: argv0).resolvingSymlinksInPath()
    }

    /// Absolute, symlink-resolved path string of the running executable.
    public static var resolvedPath: String { resolvedURL().path }
}
