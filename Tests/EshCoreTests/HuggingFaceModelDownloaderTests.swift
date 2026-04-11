import Foundation
import Testing
@testable import EshCore

@Suite(.serialized)
struct HuggingFaceModelDownloaderTests {
    @Test
    func installFailsWhenDownloadedFileSizeDoesNotMatchMetadata() async throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let session = makeSession()
        let store = FileModelStore(root: root)
        let downloader = HuggingFaceModelDownloader(
            modelStore: store,
            coordinator: DownloadCoordinator(session: session, retryPolicy: .init(maxAttempts: 1)),
            session: session,
            retryPolicy: .init(maxAttempts: 1)
        )

        DownloadTestURLProtocol.handler = { request in
            let url = try #require(request.url)
            switch url.absoluteString {
            case "https://huggingface.co/api/models/mlx-community/demo-model":
                let payload = """
                {
                  "id": "mlx-community/demo-model",
                  "sha": "abc123",
                  "siblings": [
                    { "rfilename": "config.json", "size": 2 },
                    { "rfilename": "model.safetensors", "size": 5 }
                  ]
                }
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(payload.utf8)
                )
            case "https://huggingface.co/mlx-community/demo-model/resolve/abc123/config.json":
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            case "https://huggingface.co/mlx-community/demo-model/resolve/abc123/model.safetensors":
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("1234".utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }

        await #expect(throws: StoreError.self) {
            _ = try await downloader.install(
                source: ModelSource(kind: .huggingFace, reference: "mlx-community/demo-model"),
                suggestedID: "demo-model",
                progress: { _ in }
            )
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class DownloadTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { _ in
        throw URLError(.badServerResponse)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
