#if os(macOS)
// macOS only: the MLX text backend drives a Python bridge through `Process` (one-shot subprocess or persistent
// worker), which iOS does not allow. On iOS this module provides only an unavailable `MLXBackend` (see MLXBackendUnavailable.swift).
import Foundation

/// Where MLX runtimes keep their bridge state files (prompt-cache metadata and, in the experimental token-exact
/// prefix mode, a `.kv.safetensors` sidecar), and how they are cleaned up.
///
/// Files live in `<tmp>/esh-mlx-state/` and are named `<owner pid>-<uuid>.json` (sidecars share the prefix). A
/// clean `unload()` removes a runtime's files; anything left behind by a crashed or killed owner is swept the
/// first time any MLX runtime is created in a new process — only files whose owner pid is no longer alive, so a
/// concurrently running esh process's state is never touched. (Before 2026-11 state files were loose
/// `esh-runtime-*.json` / `esh-persistent-*.json` files in the temp dir with no crash cleanup.)
enum MLXStateFiles {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("esh-mlx-state", isDirectory: true)
    }

    private static let sweepOnce: Void = { sweepStale() }()

    /// A fresh, owner-tagged state-file URL (the directory is created; stale files are swept once per process).
    static func newStateFileURL() -> URL {
        _ = sweepOnce
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(getpid())-\(UUID().uuidString).json")
    }

    /// Remove a runtime's state file and every sidecar derived from it.
    static func remove(_ stateFileURL: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: stateFileURL)
        let dir = stateFileURL.deletingLastPathComponent()
        let prefix = stateFileURL.lastPathComponent + "."
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Delete files whose owner process is gone. Returns the names removed (for tests/diagnostics).
    @discardableResult
    static func sweepStale(in dir: URL = directory, isAlive: (pid_t) -> Bool = processIsAlive) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard let dash = name.firstIndex(of: "-"), let pid = pid_t(name[..<dash]) else { continue }
            if pid == getpid() || isAlive(pid) { continue }
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { removed.append(name) }
        }
        return removed
    }

    static func processIsAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM   // exists but owned by someone else
    }
}
#endif
