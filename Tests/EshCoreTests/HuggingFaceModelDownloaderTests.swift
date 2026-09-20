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
            case "https://huggingface.co/api/models/OpenReasonAI/Graphite1.0-4B?blobs=true":
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
    func installRecordsHuggingFaceProvenanceWithoutCredentials() async throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let session = makeSession()
        let store = FileModelStore(root: root)
        let downloader = HuggingFaceModelDownloader(
            modelStore: store,
            coordinator: DownloadCoordinator(session: session, retryPolicy: .init(maxAttempts: 1)),
            session: session,
            retryPolicy: .init(maxAttempts: 1),
            provenanceContext: HFInstallProvenanceContext(licenseIdentifier: "apache-2.0", gated: true, isPrivate: false)
        )

        DownloadTestURLProtocol.handler = { request in
            let url = try #require(request.url)
            switch url.absoluteString {
            case "https://huggingface.co/api/models/mlx-community/prov-model?blobs=true":
                let payload = """
                {
                  "id": "mlx-community/prov-model",
                  "sha": "sha9999",
                  "siblings": [
                    { "rfilename": "config.json" },
                    { "rfilename": "model.safetensors" }
                  ]
                }
                """
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
            case "https://huggingface.co/mlx-community/prov-model/resolve/sha9999/config.json":
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            case "https://huggingface.co/mlx-community/prov-model/resolve/sha9999/model.safetensors":
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("weights".utf8))
            default:
                throw URLError(.badURL)
            }
        }

        let manifest = try await downloader.install(
            source: ModelSource(kind: .huggingFace, reference: "mlx-community/prov-model"),
            suggestedID: "prov-model",
            progress: { _ in }
        )
        let hf = try #require(manifest.install.huggingFace)
        #expect(hf.repoID == "mlx-community/prov-model")
        #expect(hf.revision == "sha9999")
        #expect(hf.format == "mlx")
        #expect(hf.licenseIdentifier == "apache-2.0")
        #expect(hf.gated == true)
        #expect(hf.isPrivate == false)
        #expect(hf.files.contains("config.json"))
        #expect(hf.files.contains("model.safetensors"))

        // Provenance must never carry a token; re-decode the persisted manifest and scan for hf_ tokens.
        let reloaded = try store.loadManifest(id: "prov-model")
        let json = try JSONEncoder().encode(reloaded.install)
        #expect(!String(data: json, encoding: .utf8)!.contains("hf_"))
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
            case "https://huggingface.co/api/models/example/bare-weights?blobs=true":
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
            case "https://huggingface.co/api/models/mlx-community/demo-model?blobs=true":
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
