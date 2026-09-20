import Foundation

// Minimal injectable HTTP seam for the HF metadata/access/whoami calls, so those are deterministically
// testable (mocked responses) and can carry the Authorization header when a token is present. Downloads go
// through the existing DownloadCoordinator (separately auth-threaded), not this client.

public struct HFHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public init(statusCode: Int, data: Data) { self.statusCode = statusCode; self.data = data }
}

public protocol HFHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HFHTTPResponse
}

public struct URLSessionHFHTTPClient: HFHTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> HFHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HFHTTPResponse(statusCode: code, data: data)
        } catch {
            throw HuggingFaceError.networkFailure(HFTokenRedaction.redact(error.localizedDescription))
        }
    }
}

/// Maps a URL (by absolute string, optionally matched as a prefix) to a canned response. For tests.
public final class MockHFHTTPClient: HFHTTPClient, @unchecked Sendable {
    public struct Stub: Sendable { public let statusCode: Int; public let data: Data
        public init(statusCode: Int, json: String) { self.statusCode = statusCode; self.data = Data(json.utf8) }
        public init(statusCode: Int, data: Data = Data()) { self.statusCode = statusCode; self.data = data }
    }
    private let lock = NSLock()
    private var exact: [String: Stub] = [:]
    private var prefixes: [(String, Stub)] = []
    /// Records the Authorization header seen on the last matching request (to assert token threading).
    public private(set) var lastAuthorization: String?

    public init() {}
    public func stub(url: String, _ stub: Stub) { lock.lock(); exact[url] = stub; lock.unlock() }
    public func stub(prefix: String, _ stub: Stub) { lock.lock(); prefixes.append((prefix, stub)); lock.unlock() }

    public func send(_ request: URLRequest) async throws -> HFHTTPResponse {
        let stub = resolveStub(url: request.url?.absoluteString ?? "",
                               authorization: request.value(forHTTPHeaderField: "Authorization"))
        guard let stub else { return HFHTTPResponse(statusCode: 404, data: Data()) }
        return HFHTTPResponse(statusCode: stub.statusCode, data: stub.data)
    }

    private func resolveStub(url: String, authorization: String?) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        lastAuthorization = authorization
        return exact[url] ?? prefixes.first(where: { url.hasPrefix($0.0) })?.1
    }
}
