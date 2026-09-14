import Foundation
import Darwin
import Testing
@testable import esh

@Suite
struct PortConflictResolverTests {
    /// Bind a real listening socket on an OS-assigned port so we can test detection deterministically.
    private func withListeningPort(_ body: (UInt16) -> Void) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // let the OS choose a free port
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0)
        _ = listen(fd, 1)
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        let port = UInt16(bigEndian: actual.sin_port)
        body(port)
    }

    @Test
    func detectsAnActivelyListeningPortAsUnavailable() {
        withListeningPort { port in
            #expect(PortConflictResolver.isAvailable(host: "127.0.0.1", port: port) == false)
        }
    }

    @Test
    func reportsAFreePortAsAvailable() {
        // Bind + immediately release, then the port is free again.
        var freePort: UInt16 = 0
        withListeningPort { port in freePort = port }
        #expect(freePort != 0)
        #expect(PortConflictResolver.isAvailable(host: "127.0.0.1", port: freePort) == true)
    }

    @Test
    func nextAvailablePortSkipsTheOccupiedPort() {
        withListeningPort { port in
            guard port < 65_500 else { return } // avoid wraparound at the very top
            let next = PortConflictResolver.nextAvailablePort(host: "127.0.0.1", from: port)
            #expect(next != nil)
            #expect(next != port)
            if let next { #expect(PortConflictResolver.isAvailable(host: "127.0.0.1", port: next)) }
        }
    }

    @Test
    func nonIPv4HostSkipsProbeGracefully() {
        // IPv6 host is not probed via the IPv4 path; treated as available (server will report).
        #expect(PortConflictResolver.isAvailable(host: "::1", port: 11436) == true)
    }
}
