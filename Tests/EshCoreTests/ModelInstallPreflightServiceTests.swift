import Foundation
import Testing
@testable import EshCore

@Suite(.serialized)
struct ModelInstallPreflightServiceTests {
    @Test
    func blocksUnsupportedRemoteConfigBeforeDownload() async throws {
        TestURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/raw/main/config.json")
            let data = Data(#"{"model_type":"gemma4"}"#.utf8)
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let service = ModelInstallPreflightService(
            session: makeSession(),
            runtimeValidator: MockValidator(reason: "Model type gemma4 not supported.")
        )

        let report = try await service.evaluate(
            repoID: "mlx-community/gemma-4-e2b-it-4bit",
            recommendedModel: nil,
            searchResult: nil
        )

        #expect(report.isBlocked)
        #expect(report.blockers.joined(separator: "\n").contains("gemma4"))
    }

    @Test
    func warnsWhenRemoteConfigCannotBeFetched() async throws {
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try #require(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let service = ModelInstallPreflightService(
            session: makeSession(),
            runtimeValidator: MockValidator(reason: nil)
        )

        let report = try await service.evaluate(
            repoID: "mlx-community/unknown-model",
            recommendedModel: nil,
            searchResult: nil
        )

        #expect(!report.isBlocked)
        #expect(report.warnings.count == 1)
        #expect(report.warnings[0].contains("config.json"))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct MockValidator: RemoteModelConfigValidating {
    let reason: String?

    func validateRemoteConfig(jsonText: String) throws -> String? {
        reason
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
