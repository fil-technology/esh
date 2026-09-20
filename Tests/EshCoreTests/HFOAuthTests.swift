import Foundation
import Testing
import CryptoKit
@testable import EshCore

// rc.24 §25 — deterministic OAuth protocol tests (no live network). PKCE, state, authorization URL, callback
// validation, public-client token exchange (verifier present, no secret), refresh, and token redaction.
@Suite
struct HFOAuthTests {

    private func config(redirect: String = "technology.fil.eshstudio://oauth/huggingface",
                        scopes: [String] = HFOAuthConfiguration.defaultScopes) -> HFOAuthConfiguration {
        HFOAuthConfiguration(clientID: "client-abc", redirectURI: URL(string: redirect)!, scopes: scopes)
    }

    // MARK: PKCE + state

    @Test func pkceChallengeIsS256OfVerifier() {
        let pkce = HFOAuthPKCE.generate()
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncodedString()
        #expect(pkce.challenge == expected)
        #expect(pkce.verifier.count >= 43)                       // RFC 7636 min length
        #expect(!pkce.challenge.contains("="))                   // base64url, no padding
        #expect(!pkce.challenge.contains("+") && !pkce.challenge.contains("/"))
    }

    @Test func stateTokensAreUnique() {
        let a = HFOAuthRandom.urlSafeToken(), b = HFOAuthRandom.urlSafeToken()
        #expect(a != b)
        #expect(!a.isEmpty)
    }

    // MARK: authorization URL

    @Test func authorizationURLCarriesAllRequiredFields() throws {
        let cfg = config()
        let url = HFOAuthURLBuilder.authorizationURL(configuration: cfg, state: "st8", challenge: "chal")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        func q(_ n: String) -> String? { comps.queryItems?.first { $0.name == n }?.value }
        #expect(url.absoluteString.hasPrefix("https://huggingface.co/oauth/authorize"))
        #expect(q("response_type") == "code")
        #expect(q("client_id") == "client-abc")
        #expect(q("redirect_uri") == "technology.fil.eshstudio://oauth/huggingface")
        #expect(q("scope") == "openid profile gated-repos read-repos")
        #expect(q("state") == "st8")
        #expect(q("code_challenge") == "chal")
        #expect(q("code_challenge_method") == "S256")
        #expect(comps.percentEncodedQuery?.contains("client_secret") == false)
    }

    // MARK: callback validation

    @Test func callbackParsesCodeAndState() throws {
        let cb = try HFOAuthCallback.parse(
            URL(string: "technology.fil.eshstudio://oauth/huggingface?code=abc123&state=st8")!,
            redirectURI: config().redirectURI)
        #expect(cb.code == "abc123")
        #expect(cb.state == "st8")
        #expect(cb.error == nil)
    }

    @Test func callbackMapsAccessDenied() throws {
        let cb = try HFOAuthCallback.parse(
            URL(string: "technology.fil.eshstudio://oauth/huggingface?error=access_denied&state=st8")!,
            redirectURI: config().redirectURI)
        #expect(cb.error == "access_denied")
        #expect(cb.code == nil)
    }

    @Test func callbackRejectsForeignRedirect() {
        #expect(throws: HuggingFaceError.oauthCallbackInvalid) {
            _ = try HFOAuthCallback.parse(
                URL(string: "https://evil.example.com/oauth?code=x&state=y")!,
                redirectURI: config().redirectURI)
        }
    }

    @Test func loopbackCallbackMatchesAnyPort() throws {
        let redirect = URL(string: "http://127.0.0.1/callback")!
        let cb = try HFOAuthCallback.parse(
            URL(string: "http://127.0.0.1:49821/callback?code=c&state=s")!, redirectURI: redirect)
        #expect(cb.code == "c")
    }

    @Test func customSchemeCallbackRequiresExactPath() {
        #expect(throws: HuggingFaceError.oauthCallbackInvalid) {
            _ = try HFOAuthCallback.parse(
                URL(string: "technology.fil.eshstudio://oauth/WRONG?code=c&state=s")!,
                redirectURI: config().redirectURI)
        }
    }

    // MARK: token exchange (public client)

    private func session() -> HFPendingOAuthSession {
        HFPendingOAuthSession(id: "req1", state: "st8", verifier: "verifier-xyz", configuration: config())
    }

    @Test func codeExchangeSendsVerifierAndNoSecret() async throws {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/oauth/token",
                  .init(statusCode: 200, json: #"{"access_token":"hf_oauth_tok","token_type":"bearer","expires_in":28800,"scope":"openid profile","refresh_token":"rt_1","id_token":"eyJhbGciOiJSUzI1NiJ9.e30.sig"}"#))
        let credential = try await HFOAuthClient(http: http).exchangeCode("code-9", session: session())
        // Request assertions
        let body = try #require(http.lastRequestBody)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=code-9"))
        #expect(body.contains("code_verifier=verifier-xyz"))
        #expect(body.contains("client_id=client-abc"))
        #expect(!body.contains("client_secret"))
        // Credential assertions
        #expect(credential.accessToken == "hf_oauth_tok")
        #expect(credential.method == .oauth)
        #expect(credential.refreshToken == "rt_1")
        #expect(credential.clientID == "client-abc")
        #expect(credential.expiresAt != nil)
    }

    @Test func codeExchangeFailureThrowsTyped() async {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/oauth/token", .init(statusCode: 400, json: #"{"error":"invalid_grant"}"#))
        await #expect(throws: HuggingFaceError.oauthTokenExchangeFailed) {
            _ = try await HFOAuthClient(http: MockHFHTTPClient()).exchangeCode("bad", session: self.session())
        }
        _ = http
    }

    @Test func refreshUsesRefreshTokenAndKeepsItWhenOmitted() async throws {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/oauth/token",
                  .init(statusCode: 200, json: #"{"access_token":"hf_oauth_new","token_type":"bearer","expires_in":28800,"scope":"openid profile"}"#))
        let old = HFCredential(accessToken: "hf_oauth_old", method: .oauth,
                               expiresAt: Date().addingTimeInterval(-10), scopes: ["openid"],
                               refreshToken: "rt_keep", clientID: "client-abc")
        let refreshed = try await HFOAuthClient(http: http).refresh(old, tokenEndpoint: URL(string: "https://huggingface.co/oauth/token")!)
        let body = try #require(http.lastRequestBody)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=rt_keep"))
        #expect(refreshed.accessToken == "hf_oauth_new")
        #expect(refreshed.refreshToken == "rt_keep")            // carried over when HF omits a new one
    }

    @Test func pendingSessionExpires() {
        let fresh = HFPendingOAuthSession(id: "a", state: "s", verifier: "v", configuration: config())
        #expect(!fresh.isExpired())
        let stale = HFPendingOAuthSession(id: "b", state: "s", verifier: "v", configuration: config(),
                                          createdAt: Date().addingTimeInterval(-3600))
        #expect(stale.isExpired())          // TTL 600s → an hour-old session is expired
    }

    @Test func credentialExpiryAndRefreshability() {
        let pat = HFCredential(accessToken: "hf_x", method: .pat)
        #expect(!pat.isExpired())           // no expiry → never expires locally
        #expect(!pat.canRefresh)
        let expired = HFCredential(accessToken: "t", method: .oauth,
                                   expiresAt: Date().addingTimeInterval(-10),
                                   refreshToken: "rt", clientID: "c")
        #expect(expired.isExpired())
        #expect(expired.canRefresh)
        let noRefresh = HFCredential(accessToken: "t", method: .oauth,
                                     expiresAt: Date().addingTimeInterval(-10))
        #expect(!noRefresh.canRefresh)      // expired + no refresh → reauth required
    }

    // MARK: redaction

    @Test func redactionScrubsOAuthShapes() {
        let s = "tok hf_oauth_ABC123 pat hf_XYZ jwt eyJhbGciOi.J9payload.sig auth Bearer opaqueTok"
        let r = HFTokenRedaction.redact(s)
        #expect(!r.contains("hf_oauth_ABC123"))
        #expect(!r.contains("hf_XYZ"))
        #expect(!r.contains("eyJhbGciOi.J9payload.sig"))
        #expect(!r.contains("opaqueTok"))
        #expect(r.contains("Bearer ***"))
    }

    // MARK: credential store migration

    @Test func inMemoryStoreMigratesLegacyPATSeed() {
        let store = InMemoryHFCredentialStore(token: "hf_legacy")
        let cred = store.loadCredential()
        #expect(cred?.accessToken == "hf_legacy")
        #expect(cred?.method == .pat)
        #expect(store.loadToken() == "hf_legacy")   // universal accessor still works
    }
}
