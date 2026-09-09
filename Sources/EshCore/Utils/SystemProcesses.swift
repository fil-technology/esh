import Foundation

// Best-effort "what's using the most RAM" probe, used to make a low-memory refusal actionable ("Google Drive
// is using 7.3 GB — close it and try again"). Shells out to `ps` (like the RAM guard shells out to vm_stat);
// returns nil when it can't be read. Never fatal — purely advisory text.
public enum SystemProcesses {
    public struct Consumer: Sendable { public let name: String; public let gigabytes: Double }

    /// The largest user-facing memory consumer right now, excluding things the user can't act on
    /// (kernel_task, WindowServer) and esh's own processes. nil if unavailable.
    public static func topConsumer(excludingPIDs excluded: Set<Int32> = []) -> Consumer? {
        let out: String
        do {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            // -m: sort by memory; rss in KB + full command. Own PID excluded below.
            p.arguments = ["-axo", "pid=,rss=,comm="]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            out = String(data: data, encoding: .utf8) ?? ""
        } catch {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let skipNames = ["kernel_task", "WindowServer", "ps"]
        // Scan every process and keep the single largest RSS (ps ordering isn't reliable across flags),
        // aggregating multi-process apps (helpers share the app name) so e.g. a browser reads as one number.
        var byName: [String: Double] = [:]
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[..<firstSpace]) else { continue }
            let rest = trimmed[trimmed.index(after: firstSpace)...].trimmingCharacters(in: .whitespaces)
            guard let secondSpace = rest.firstIndex(of: " "), let rssKB = Int64(rest[..<secondSpace]) else { continue }
            let command = String(rest[rest.index(after: secondSpace)...])
            if pid == ownPID || excluded.contains(pid) { continue }
            let name = displayName(fromCommand: command)
            if skipNames.contains(where: { name == $0 }) { continue }
            if command.contains("mlx_vlm_bridge") || command.hasSuffix("/esh") { continue }   // our own workers
            byName[name, default: 0] += Double(rssKB) / 1_048_576.0
        }
        guard let top = byName.max(by: { $0.value < $1.value }), top.value >= 0.5 else { return nil }
        return Consumer(name: top.key, gigabytes: top.value)
    }

    /// Turn a full command path into a human app name: "/Applications/Google Drive.app/…/Google Drive" →
    /// "Google Drive"; otherwise the last path component.
    private static func displayName(fromCommand command: String) -> String {
        if let range = command.range(of: ".app/") {
            let beforeApp = command[..<range.lowerBound]
            if let slash = beforeApp.lastIndex(of: "/") {
                return String(beforeApp[beforeApp.index(after: slash)...])
            }
        }
        return String(command.split(separator: "/").last ?? Substring(command))
    }
}
