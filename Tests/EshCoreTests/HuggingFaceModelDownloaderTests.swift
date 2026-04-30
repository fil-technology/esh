import Foundation
import Testing
@testable import EshCore

@Suite(.serialized)
struct HuggingFaceModelDownloaderTests {
    @Test
    func installRecordsBaseModelForPEFTAdapterRepo() async throws {
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
            case "https://huggingface.co/api/models/OpenReasonAI/Graphite1.0-4B":
                let payload = """
                {
                  "id": "OpenReasonAI/Graphite1.0-4B",
                  "sha": "adapter123",
                  "library_name": "peft",
                  "tags": ["peft", "lora", "qwen", "base_model:adapter:Qwen/Qwen3.5-4B-Base"],
                  "siblings": [
                    { "rfilename": "adapter_config.json" },
                    { "rfilename": "adapter_model.safetensors" },
                    { "rfilename": "tokenizer.json" }
                  ]
                }
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(payload.utf8)
                )
            case "https://huggingface.co/OpenReasonAI/Graphite1.0-4B/resolve/adapter123/adapter_config.json":
                let data = Data(#"{"base_model_name_or_path":"Qwen/Qwen3.5-4B-Base"}"#.utf8)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data
                )
            case "https://huggingface.co/OpenReasonAI/Graphite1.0-4B/resolve/adapter123/adapter_model.safetensors":
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("weights".utf8)
                )
            case "https://huggingface.co/OpenReasonAI/Graphite1.0-4B/resolve/adapter123/tokenizer.json":
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }

        let manifest = try await downloader.install(
            source: ModelSource(kind: .huggingFace, reference: "OpenReasonAI/Graphite1.0-4B"),
            suggestedID: "openreasonai--graphite1.0-4b",
            progress: { _ in }
        )

        #expect(manifest.install.spec.baseModelID == "Qwen/Qwen3.5-4B-Base")
        #expect(manifest.install.spec.variant == "adapter")
    }

    @Test
    func installRejectsSafetensorsRepoWithoutConfigOrAdapterMetadata() async throws {
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
            case "https://huggingface.co/api/models/example/bare-weights":
                let payload = """
                {
                  "id": "example/bare-weights",
                  "sha": "bare123",
                  "siblings": [
                    { "rfilename": "model.safetensors" }
                  ]
                }
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(payload.utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }

        do {
            _ = try await downloader.install(
                source: ModelSource(kind: .huggingFace, reference: "example/bare-weights"),
                suggestedID: "bare-weights",
                progress: { _ in }
            )
            Issue.record("Expected install to reject bare safetensors without model metadata.")
        } catch {
            #expect(error.localizedDescription.contains("config.json or adapter_config.json"))
        }
    }

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
