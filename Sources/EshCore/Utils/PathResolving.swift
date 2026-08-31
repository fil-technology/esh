import Foundation

/// Standardized path expansion used across esh so `~`, `$HOME`, relative, and absolute paths
/// (including ones with spaces/unicode) are handled identically everywhere. Replaces the
/// previously duplicated tilde-expansion snippets in EngineOrchestratorService,
/// LocalModelValidationService, and ValidateCommand.
public enum PathResolving {
    /// Expand a user-supplied path string into an absolute file URL.
    /// - `~` / `~/...` expand to the home directory.
    /// - `$HOME/...` expands to the home directory.
    /// - relative paths resolve against `base` (defaults to the current working directory).
    /// - absolute paths are used as-is.
    public static func url(
        from rawPath: String,
        base: URL? = nil,
        isDirectory: Bool = false
    ) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser

        var expanded = trimmed
        if expanded == "~" {
            return home
        }
        if expanded.hasPrefix("~/") {
            return home.appendingPathComponent(String(expanded.dropFirst(2)), isDirectory: isDirectory)
        }
        if expanded.hasPrefix("$HOME/") {
            return home.appendingPathComponent(String(expanded.dropFirst("$HOME/".count)), isDirectory: isDirectory)
        }
        // Fall back to NSString tilde expansion for forms like ~user (best effort).
        if expanded.hasPrefix("~") {
            expanded = (expanded as NSString).expandingTildeInPath
        }

        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: isDirectory)
        }

        let base = base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return base.appendingPathComponent(expanded, isDirectory: isDirectory)
    }

    /// Standardized directory URL (trailing-slash semantics) for a raw path string.
    public static func directoryURL(from rawPath: String, base: URL? = nil) -> URL {
        url(from: rawPath, base: base, isDirectory: true)
    }
}
