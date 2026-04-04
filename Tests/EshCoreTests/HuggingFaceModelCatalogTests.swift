import Foundation
import Testing
@testable import EshCore

@Suite(.serialized)
struct HuggingFaceModelCatalogTests {
    @Test
    func searchIncludesGGUFAndDoesNotForceMLXAppFilter() async throws {
        TestHFURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(url.absoluteString.contains("search=qwen"))
            #expect(url.absoluteString.contains("apps=mlx-lm") == false)

            let payload = """
            [
              {
                "id": "bartowski/Qwen2.5-7B-Instruct-GGUF",
                "pipelineTag": "text-generation",
                "tags": ["gguf"],
                "downloads": 123,
                "siblings": [
                  { "rfilename": "Qwen2.5-7B-Instruct-Q4_K_M.gguf", "size": 1000 }
                ]
              },
              {
                "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
                "pipelineTag": "text-generation",
                "tags": ["mlx"],
                "downloads": 456,
                "siblings": [
                  { "rfilename": "model.safetensors", "size": 1000 },
                  { "rfilename": "config.json", "size": 100 }
                ]
              }
            ]
            """
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }

        let catalog = HuggingFaceModelCatalog(session: makeSession())
        let results = try await catalog.search(query: "qwen", limit: 10)

        #expect(results.count == 2)
        #expect(results.contains { $0.id == "bartowski/Qwen2.5-7B-Instruct-GGUF" && $0.backend == .gguf })
        #expect(results.contains { $0.id == "mlx-community/Qwen2.5-7B-Instruct-4bit" && $0.backend == .mlx })
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestHFURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TestHFURLProtocol: URLProtocol, @unchecked Sendable {
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
