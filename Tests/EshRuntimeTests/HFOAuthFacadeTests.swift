import Foundation
import Testing
@testable import EshRuntime
@testable import EshCore

// rc.24 §25/§26 — EshRuntime OAuth facade + credential migration, fully mocked. Covers begin/complete,
// state validation, atomic credential replacement, disconnect, PAT coexistence, and OAuth-token threading.
@Suite
struct HFOAuthFacadeTests {
    private let redirect = "technology.fil.eshstudio://oauth/huggingface"

    private func config() -> HFOAuthConfiguration {
        HFOAuthConfiguration(clientID: "client-abc", redirectURI: URL(string: redirect)!)
    }
    private func makeRuntime(http: MockHFHTTPClient, creds: HFCredentialStore) async -> EshRuntime {
        let rt = EshRuntime(registry: InferenceBackendRegistry(backends: [:]))
        await rt.configureHuggingFace(credentials: creds, http: http)
        return rt
    }
    private func stateOf(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
    }
    private func stubHappyOAuth(_ http: MockHFHTTPClient, username: String = "carol", token: String = "hf_oauth_tok") {
        http.stub(url: "https://huggingface.co/oauth/token",
                  .init(statusCode: 200, json: #"{"access_token":"\#(token)","token_type":"bearer","expires_in":28800,"scope":"openid profile"}"#))
        http.stub(url: "https://huggingface.co/api/whoami-v2", .init(statusCode: 200, json: #"{"name":"\#(username)"}"#))
    }

    @Test func beginProducesValidAuthorizationURL() async throws {
        let rt = await makeRuntime(http: MockHFHTTPClient(), creds: InMemoryHFCredentialStore())
        let req = try await rt.beginHuggingFaceOAuth(configuration: config())
        let comps = try #require(URLComponents(url: req.authorizationURL, resolvingAgainstBaseURL: false))
        func q(_ n: String) -> String? { comps.queryItems?.first { $0.name == n }?.value }
        #expect(q("client_id") == "client-abc")
        #expect(q("redirect_uri") == redirect)
        #expect(q("code_challenge_method") == "S256")
        #expect(q("scope") == "openid profile gated-repos read-repos")
        #expect(!(q("state") ?? "").isEmpty)
    }

    @Test func beginRejectsEmptyConfiguration() async {
        let rt = await makeRuntime(http: MockHFHTTPClient(), creds: InMemoryHFCredentialStore())
        let bad = HFOAuthConfiguration(clientID: "", redirectURI: URL(string: redirect)!)
        await #expect(throws: HuggingFaceError.oauthConfigurationInvalid) {
            _ = try await rt.beginHuggingFaceOAuth(configuration: bad)
        }
    }

    @Test func completeHappyPathConnects() async throws {
        let http = MockHFHTTPClient(); stubHappyOAuth(http)
        let creds = InMemoryHFCredentialStore()
        let rt = await makeRuntime(http: http, creds: creds)
        let req = try await rt.beginHuggingFaceOAuth(configuration: config())
        let cb = URL(string: "\(redirect)?code=thecode&state=\(stateOf(req.authorizationURL))")!
        let account = try await rt.completeHuggingFaceOAuth(callbackURL: cb, requestID: req.id)
        #expect(account == .connected(username: "carol"))
        let stored = creds.loadCredential()
        #expect(stored?.method == .oauth)
        #expect(stored?.accessToken == "hf_oauth_tok")
    }

    @Test func completeRejectsStateMismatch() async throws {
        let http = MockHFHTTPClient(); stubHappyOAuth(http)
        let rt = await makeRuntime(http: http, creds: InMemoryHFCredentialStore())
        let req = try await rt.beginHuggingFaceOAuth(configuration: config())
        let cb = URL(string: "\(redirect)?code=thecode&state=WRONG")!
        await #expect(throws: HuggingFaceError.oauthStateMismatch) {
            _ = try await rt.completeHuggingFaceOAuth(callbackURL: cb, requestID: req.id)
        }
    }

    @Test func completeRejectsUnknownSession() async {
        let rt = await makeRuntime(http: MockHFHTTPClient(), creds: InMemoryHFCredentialStore())
        let cb = URL(string: "\(redirect)?code=c&state=s")!
        await #expect(throws: HuggingFaceError.oauthSessionNotFound) {
            _ = try await rt.completeHuggingFaceOAuth(callbackURL: cb, requestID: "nope")
        }
    }

    @Test func completeMapsAccessDenied() async throws {
        let rt = await makeRuntime(http: MockHFHTTPClient(), creds: InMemoryHFCredentialStore())
        let req = try await rt.beginHuggingFaceOAuth(configuration: config())
        let cb = URL(string: "\(redirect)?error=access_denied&state=\(stateOf(req.authorizationURL))")!
        await #expect(throws: HuggingFaceError.oauthAccessDenied) {
            _ = try await rt.completeHuggingFaceOAuth(callbackURL: cb, requestID: req.id)
        }
    }

    @Test func failedExchangeKeepsExistingCredential() async throws {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/oauth/token", .init(statusCode: 400, json: #"{"error":"invalid_grant"}"#))
        let creds = InMemoryHFCredentialStore(token: "hf_existing_pat")   // a working PAT already connected
        let rt = await makeRuntime(http: http, creds: creds)
        let req = try await rt.beginHuggingFaceOAuth(configuration: config())
        let cb = URL(string: "\(redirect)?code=thecode&state=\(stateOf(req.authorizationURL))")!
        await #expect(throws: HuggingFaceError.oauthTokenExchangeFailed) {
            _ = try await rt.completeHuggingFaceOAuth(callbackURL: cb, requestID: req.id)
        }
        #expect(creds.loadCredential()?.accessToken == "hf_existing_pat")   // untouched
        #expect(creds.loadCredential()?.method == .pat)
    }

    @Test func successfulOAuthReplacesExistingPATAtomically() async throws {
        let http = MockHFHTTPClient(); stubHappyOAuth(http, token: "hf_oauth_new")
        let creds = InMemoryHFCredentialStore(token: "hf_old_pat")
        let rt = await makeRuntime(http: http, creds: creds)
        let req = try await rt.beginHuggingFaceOAuth(configuration: config())
        let cb = URL(string: "\(redirect)?code=c&state=\(stateOf(req.authorizationURL))")!
        _ = try await rt.completeHuggingFaceOAuth(callbackURL: cb, requestID: req.id)
        #expect(creds.loadCredential()?.method == .oauth)
        #expect(creds.loadCredential()?.accessToken == "hf_oauth_new")
    }

    @Test func disconnectClearsOAuthCredential() async throws {
        let http = MockHFHTTPClient(); stubHappyOAuth(http)
        let creds = InMemoryHFCredentialStore()
        let rt = await makeRuntime(http: http, creds: creds)
        let req = try await rt.beginHuggingFaceOAuth(configuration: config())
        let cb = URL(string: "\(redirect)?code=c&state=\(stateOf(req.authorizationURL))")!
        _ = try await rt.completeHuggingFaceOAuth(callbackURL: cb, requestID: req.id)
        await rt.disconnectHuggingFace()
        #expect(creds.loadCredential() == nil)
        #expect(await rt.huggingFaceAccountState() == .disconnected)
    }

    @Test func manualPATStillWorks() async throws {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/api/whoami-v2", .init(statusCode: 200, json: #"{"name":"dave"}"#))
        let creds = InMemoryHFCredentialStore()
        let rt = await makeRuntime(http: http, creds: creds)
        let name = try await rt.connectHuggingFace(token: "hf_pat_manual")
        #expect(name == "dave")
        #expect(creds.loadCredential()?.method == .pat)
        #expect(creds.loadCredential()?.accessToken == "hf_pat_manual")
    }

    @Test func oauthTokenDrivesAuthenticatedResolve() async throws {
        let http = MockHFHTTPClient(); stubHappyOAuth(http, token: "hf_oauth_drive")
        http.stub(prefix: "https://huggingface.co/api/models/acme/pub",
                  .init(statusCode: 200, json: #"{"id":"acme/pub","private":false,"gated":false,"siblings":[{"rfilename":"config.json"}]}"#))
        let rt = await makeRuntime(http: http, creds: InMemoryHFCredentialStore())
        let req = try await rt.beginHuggingFaceOAuth(configuration: config())
        let cb = URL(string: "\(redirect)?code=c&state=\(stateOf(req.authorizationURL))")!
        _ = try await rt.completeHuggingFaceOAuth(callbackURL: cb, requestID: req.id)
        _ = try await rt.resolveHuggingFace(reference: "acme/pub")
        #expect(http.lastAuthorization == "Bearer hf_oauth_drive")   // OAuth token threaded into authed HF requests
    }

    @Test func migratedPATReportsConnectedThenOAuthReplaces() async throws {
        // Simulate an existing rc.23 PAT already in the store (migration): account is connected, requests work.
        let http = MockHFHTTPClient(); stubHappyOAuth(http, username: "erin", token: "hf_oauth_after")
        let creds = InMemoryHFCredentialStore(credential: HFCredential(accessToken: "hf_pat_legacy", method: .pat))
        let rt = await makeRuntime(http: http, creds: creds)
        #expect(await rt.huggingFaceAccountState() == .connected(username: "erin"))
        // Then OAuth connect replaces it atomically, no forced logout in between.
        let req = try await rt.beginHuggingFaceOAuth(configuration: config())
        let cb = URL(string: "\(redirect)?code=c&state=\(stateOf(req.authorizationURL))")!
        _ = try await rt.completeHuggingFaceOAuth(callbackURL: cb, requestID: req.id)
        #expect(creds.loadCredential()?.method == .oauth)
        #expect(creds.loadCredential()?.accessToken == "hf_oauth_after")
    }
}
