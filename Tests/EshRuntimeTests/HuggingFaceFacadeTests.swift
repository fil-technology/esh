import Foundation
import Testing
@testable import EshRuntime
@testable import EshCore

// HF9 — the EshRuntime Hugging Face facade delegates to the (mocked) source with an injected credential
// store + HTTP client. Verifies configuration injection, account/connect flow, and resolve delegation.
@Suite
struct HuggingFaceFacadeTests {

    private func makeRuntime(http: MockHFHTTPClient, creds: HFCredentialStore) async -> EshRuntime {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [:]))
        await runtime.configureHuggingFace(credentials: creds, http: http)
        return runtime
    }

    @Test func accountStateFlowsThroughRuntime() async {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/api/whoami-v2", .init(statusCode: 200, json: #"{"name":"carol"}"#))
        let runtime = await makeRuntime(http: http, creds: InMemoryHFCredentialStore(token: "hf_x"))
        #expect(await runtime.huggingFaceAccountState() == .connected(username: "carol"))
    }

    @Test func connectStoresTokenAndDisconnectClears() async throws {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/api/whoami-v2", .init(statusCode: 200, json: #"{"name":"dave"}"#))
        let creds = InMemoryHFCredentialStore()
        let runtime = await makeRuntime(http: http, creds: creds)
        let name = try await runtime.connectHuggingFace(token: "hf_ok")
        #expect(name == "dave")
        #expect(creds.loadToken() == "hf_ok")
        await runtime.disconnectHuggingFace()
        #expect(creds.loadToken() == nil)
    }

    @Test func resolveDelegatesAndThrowsTypedErrorOnNotFound() async {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/api/models/owner/missing", .init(statusCode: 404))
        let runtime = await makeRuntime(http: http, creds: InMemoryHFCredentialStore())
        await #expect(throws: HuggingFaceError.repositoryNotFound) {
            _ = try await runtime.resolveHuggingFace(reference: "owner/missing")
        }
    }

    @Test func parsesReferenceNonisolated() async {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [:]))
        #expect(runtime.parseHuggingFaceReference("owner/repo")?.reference == "owner/repo")
        #expect(runtime.parseHuggingFaceReference("nonsense here") == nil)
    }
}
