import Foundation
import Testing
@testable import EshCore

@Suite(.serialized)
struct ModelInstallPreflightServiceTests {
    @Test
    func blocksUnsupportedGGUFBeforeDownload() async throws {
        TestURLProtocol.handler = { request in
            let url = try #require(request.url)
            switch url.absoluteString {
            case "https://huggingface.co/api/models/bartowski/demo-GGUF":
                let data = Data(#"{"id":"bartowski/demo-GGUF","pipelineTag":"text-generation","tags":["multimodal"],"siblings":[{"rfilename":"demo-q4_k_m.gguf","size":4294967296}]}"#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            case "https://huggingface.co/bartowski/demo-GGUF/raw/main/config.json":
                let data = Data(#"{"model_type":"qwen2"}"#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            default:
                throw URLError(.badURL)
            }
        }

        let service = ModelInstallPreflightService(
            session: makeSession()
        )

        let report = try await service.evaluate(
            repoID: "bartowski/demo-GGUF",
            recommendedModel: nil,
            searchResult: nil
        )

        #expect(report.isBlocked)
        #expect(report.blockers.joined(separator: "\n").contains("unsupported_architecture"))
    }

    @Test
    func forceAllowsUnsupportedRuntimeVerdictBeforeDownload() async throws {
        TestURLProtocol.handler = { request in
            let url = try #require(request.url)
            switch url.absoluteString {
            case "https://huggingface.co/api/models/bartowski/demo-GGUF":
                let data = Data(#"{"id":"bartowski/demo-GGUF","pipelineTag":"text-generation","tags":["multimodal"],"siblings":[{"rfilename":"demo-q4_k_m.gguf","size":4294967296}]}"#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            case "https://huggingface.co/bartowski/demo-GGUF/raw/main/config.json":
                let data = Data(#"{"model_type":"qwen2"}"#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            default:
                throw URLError(.badURL)
            }
        }

        let service = ModelInstallPreflightService(
            session: makeSession()
        )

        let report = try await service.evaluate(
            repoID: "bartowski/demo-GGUF",
            recommendedModel: nil,
            searchResult: nil,
            forceUnsupportedRuntime: true
        )

        #expect(!report.isBlocked)
        #expect(report.notes.joined(separator: "\n").contains("unsupported_architecture"))
        #expect(report.warnings.joined(separator: "\n").contains("Force install requested"))
    }

    @Test
    func warnsWhenMetadataCannotBeFetched() async throws {
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try #require(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let service = ModelInstallPreflightService(
            session: makeSession()
        )

        let report = try await service.evaluate(
            repoID: "mlx-community/unknown-model",
            recommendedModel: nil,
            searchResult: nil
        )

        #expect(!report.isBlocked)
        #expect(report.warnings.count >= 1)
        #expect(report.warnings.joined(separator: "\n").contains("Could not verify runtime compatibility"))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
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
