import Foundation
import Testing
@testable import EshCore

// Serialized: the tests share the URLProtocol's static handler/seenRanges (global download interception).
@Suite(.serialized)
struct DownloadCoordinatorTests {
    @Test
    func existingSizeUsesPartialFileLength() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("partial.bin")
        try Data(repeating: 1, count: 128).write(to: fileURL)

        #expect(ResumeSupport.existingSize(at: fileURL) == 128)
    }

    // MARK: block-reading download (rc.26 exFAT/CPU fix)

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dlc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ChunkedTestURLProtocol.self]
        return URLSession(configuration: cfg)
    }
    private func plan(size: Int64) -> DownloadPlan {
        DownloadPlan(repoID: "acme/model", revision: "main", files: [.init(path: "weights.bin", sizeBytes: size)])
    }
    private func url(for path: String) -> String { "https://huggingface.co/acme/model/resolve/main/\(path)" }

    /// The body is delivered in several `Data` blocks; the coordinator must reassemble every byte on disk
    /// (proves the read is block-based and lossless — the old per-`UInt8` loop is gone).
    @Test func downloadReassemblesMultipleChunks() async throws {
        let body = Data((0..<(300_000)).map { UInt8($0 % 251) })   // ~293 KB, non-trivial pattern
        ChunkedTestURLProtocol.seenRanges = []
        ChunkedTestURLProtocol.handler = { _ in .ok(fullBody: body, chunkSize: 64 * 1024) }   // multiple blocks
        let dir = tempDir()
        let coordinator = DownloadCoordinator(session: makeSession(), retryPolicy: .init(maxAttempts: 1))
        let recorder = ProgressRecorder()
        let files = try await coordinator.download(plan: plan(size: Int64(body.count)), into: dir, reporter: ClosureProgressReporter { recorder.record($0) })
        #expect(files == ["weights.bin"])
        #expect(ChunkedTestURLProtocol.seenRanges == ["nil"])            // fresh download, no Range header
        let onDisk = try Data(contentsOf: dir.appendingPathComponent("weights.bin"))
        #expect(onDisk == body)                                          // every byte intact across blocks
        // Progress advances on the ~64 KB cadence (no final flush emit, by design) — within one cadence of total.
        #expect(recorder.maxBytesDownloaded >= Int64(body.count) - 64 * 1024)
        #expect(recorder.maxBytesDownloaded <= Int64(body.count))
    }

    /// A partial file on disk → the coordinator sends `Range: bytes=<k>-` and appends only the remainder,
    /// yielding the complete, correct file.
    @Test func resumeAppendsRemainingViaRangeHeader() async throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let already = 80_000
        let dir = tempDir()
        let dest = dir.appendingPathComponent("weights.bin")
        try body.prefix(already).write(to: dest)                        // pre-existing partial

        ChunkedTestURLProtocol.seenRanges = []
        ChunkedTestURLProtocol.handler = { _ in
            .partial(remaining: body.suffix(from: already), fullSize: body.count, chunkSize: 32 * 1024)
        }
        let coordinator = DownloadCoordinator(session: makeSession(), retryPolicy: .init(maxAttempts: 1))
        _ = try await coordinator.download(plan: plan(size: Int64(body.count)), into: dir, reporter: ClosureProgressReporter { _ in })
        #expect(ChunkedTestURLProtocol.seenRanges == ["bytes=\(already)-"])   // resumed from the partial offset
        #expect(try Data(contentsOf: dest) == body)
    }

    /// A resume request that gets 416 → delete the partial, restart from 0, produce the correct full file.
    @Test func restartsFromZeroOn416() async throws {
        let body = Data((0..<150_000).map { UInt8(($0 * 7) % 251) })
        let dir = tempDir()
        let dest = dir.appendingPathComponent("weights.bin")
        try body.prefix(50_000).write(to: dest)                         // stale partial

        ChunkedTestURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Range") != nil {
                return .status(416)                                      // range not satisfiable → restart
            }
            return .ok(fullBody: body, chunkSize: 64 * 1024)            // fresh full download
        }
        let coordinator = DownloadCoordinator(session: makeSession(), retryPolicy: .init(maxAttempts: 1))
        _ = try await coordinator.download(plan: plan(size: Int64(body.count)), into: dir, reporter: ClosureProgressReporter { _ in })
        #expect(try Data(contentsOf: dest) == body)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _max: Int64 = 0
    func record(_ s: DownloadState) { lock.lock(); _max = Swift.max(_max, s.bytesDownloaded); lock.unlock() }
    var maxBytesDownloaded: Int64 { lock.lock(); defer { lock.unlock() }; return _max }
}

// A URLProtocol that can deliver a body in multiple `Data` blocks, honor Range (206), or return a bare status.
private final class ChunkedTestURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case ok(fullBody: Data, chunkSize: Int)
        case partial(remaining: Data, fullSize: Int, chunkSize: Int)
        case status(Int)
    }
    nonisolated(unsafe) static var handler: @Sendable (URLRequest) -> Reply = { _ in .status(500) }
    nonisolated(unsafe) static var seenRanges: [String] = []
    private static let seenLock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.seenLock.lock()
        Self.seenRanges.append(request.value(forHTTPHeaderField: "Range") ?? "nil")
        Self.seenLock.unlock()
        let reply = Self.handler(request)
        let url = request.url!
        switch reply {
        case let .ok(body, chunkSize):
            respond(url: url, status: 200, headers: ["Content-Length": "\(body.count)"], body: body, chunkSize: chunkSize)
        case let .partial(remaining, fullSize, chunkSize):
            let start = fullSize - remaining.count
            respond(url: url, status: 206,
                    headers: ["Content-Length": "\(remaining.count)",
                              "Content-Range": "bytes \(start)-\(fullSize - 1)/\(fullSize)"],
                    body: Data(remaining), chunkSize: chunkSize)
        case let .status(code):
            let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func respond(url: URL, status: Int, headers: [String: String], body: Data, chunkSize: Int) {
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < body.count {
            let end = min(offset + chunkSize, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))   // one block per call
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
