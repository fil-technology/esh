import Foundation
import Darwin
import EshCore

/// Resolves "Address already in use" before the server tries (and fails) to bind. When the requested
/// port is taken, esh no longer prints a raw POSIX error and hangs — instead it either offers to stop
/// an existing esh server on that port, moves to a free port, or (non-interactive) auto-selects the
/// next free port. Only esh's own processes are ever offered for termination.
enum PortConflictResolver {
    /// The outcome of resolving a requested port.
    enum Resolution {
        case useRequested            // the requested port was free (or freed by stopping esh)
        case useAlternate(UInt16)    // fall back to this free port instead
        case cancelled               // the user chose not to proceed
    }

    /// Resolve `port` on `host`, prompting when a TTY is attached and auto-selecting otherwise.
    static func resolve(host: String, port: UInt16) -> Resolution {
        if isAvailable(host: host, port: port) { return .useRequested }

        let holders = listeningPIDs(port: port)
        let eshHolders = holders.filter { isEshProcess($0) }
        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0

        guard interactive else {
            // Non-interactive: don't kill anything; just move to a free port so scripts keep working.
            if let alt = nextAvailablePort(host: host, from: port) {
                fputs("notice: port \(port) is in use; using free port \(alt) instead.\n", stderr)
                return .useAlternate(alt)
            }
            fputs("error: port \(port) is in use and no free port was found nearby.\n", stderr)
            return .cancelled
        }

        // Interactive prompt.
        if eshHolders.isEmpty {
            let who = holders.isEmpty ? "another process" : "another process (pid \(holders.map(String.init).joined(separator: ", ")))"
            print("Port \(port) is already in use by \(who), which is not an esh server.")
            print("  [o] open on a different port   [c] cancel")
            switch choice(allowStop: false) {
            case "o": return alternateOrCancel(host: host, port: port)
            default: return .cancelled
            }
        }

        print("Port \(port) is already in use by an esh server (pid \(eshHolders.map(String.init).joined(separator: ", "))).")
        print("  [s] stop it and start here   [o] open on a different port   [c] cancel")
        switch choice(allowStop: true) {
        case "s":
            stop(pids: eshHolders)
            if waitUntilFree(host: host, port: port) {
                print("Stopped the previous esh server; starting on port \(port).")
                return .useRequested
            }
            print("Could not free port \(port) in time; choosing another port.")
            return alternateOrCancel(host: host, port: port)
        case "o":
            return alternateOrCancel(host: host, port: port)
        default:
            return .cancelled
        }
    }

    private static func alternateOrCancel(host: String, port: UInt16) -> Resolution {
        if let alt = nextAvailablePort(host: host, from: port) {
            print("Using free port \(alt).")
            return .useAlternate(alt)
        }
        print("No free port found nearby.")
        return .cancelled
    }

    private static func choice(allowStop: Bool) -> String {
        FileHandle.standardOutput.write(Data("> ".utf8))
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return "c"
        }
        let first = String(line.first ?? "c")
        if first == "s" && !allowStop { return "c" }
        return ["s", "o", "c"].contains(first) ? first : "c"
    }

    // MARK: - Port probing

    /// True if `port` can be bound on `host` right now (i.e. it is free).
    static func isAvailable(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true } // can't probe; let the server try.
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        let ip = (host == "localhost") ? "127.0.0.1" : host
        // Non-IPv4 host (e.g. "::"/"::1"): skip the probe and let the server report.
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return true }
        // Deliberately do NOT set SO_REUSEADDR — we want an active listener to make bind() fail.
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    static func nextAvailablePort(host: String, from port: UInt16, attempts: Int = 64) -> UInt16? {
        var candidate = UInt32(port) + 1
        var tried = 0
        while candidate <= 65_535 && tried < attempts {
            let value = UInt16(candidate)
            if isAvailable(host: host, port: value) { return value }
            candidate += 1
            tried += 1
        }
        return nil
    }

    private static func waitUntilFree(host: String, port: UInt16, timeoutSeconds: Double = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isAvailable(host: host, port: port) { return true }
            usleep(150_000)
        }
        return isAvailable(host: host, port: port)
    }

    // MARK: - Process inspection

    static func listeningPIDs(port: UInt16) -> [Int32] {
        for lsof in ["/usr/sbin/lsof", "/usr/bin/lsof"] where FileManager.default.isExecutableFile(atPath: lsof) {
            guard let output = try? ProcessRunner.run(
                executableURL: URL(fileURLWithPath: lsof),
                arguments: ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
            ) else { continue }
            let pids = String(decoding: output.stdout, as: UTF8.self)
                .split(whereSeparator: { $0 == "\n" || $0 == " " })
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            if !pids.isEmpty { return Array(Set(pids)) }
        }
        return []
    }

    private static func processName(_ pid: Int32) -> String? {
        guard let output = try? ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "comm="]
        ) else { return nil }
        let name = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func isEshProcess(_ pid: Int32) -> Bool {
        guard let name = processName(pid) else { return false }
        let base = (name as NSString).lastPathComponent
        return base == "esh" || name.hasSuffix("/esh")
    }

    private static func stop(pids: [Int32]) {
        for pid in pids { _ = kill(pid, SIGTERM) }
        // Give them a moment to exit cleanly, then force any survivors.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return }
            usleep(150_000)
        }
        for pid in pids where kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
    }
}
