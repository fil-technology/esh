import Foundation
import CryptoKit

// Hugging Face OAuth — Authorization Code + PKCE for a PUBLIC client (no secret), rc.24. esh owns the OAuth
// protocol: PKCE, state, the authorization URL, callback validation, code/refresh token exchange, and
// credential persistence (through the existing rc.23 credential abstraction). The consumer app owns the
// browser and callback delivery only. Verified against HF's live OIDC discovery + docs:
//   authorize = https://huggingface.co/oauth/authorize
//   token     = https://huggingface.co/oauth/token
//   userinfo  = https://huggingface.co/oauth/userinfo
//   PKCE S256 supported; public apps authenticate with client_id only (no client_secret).

/// Configuration for a public OAuth client. The consumer app supplies these; none of it is secret. Endpoints
/// default to Hugging Face and are overridable for tests.
public struct HFOAuthConfiguration: Sendable, Equatable {
    public var clientID: String
    public var redirectURI: URL
    public var scopes: [String]
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var userInfoEndpoint: URL
    /// Least-privilege default for gated + private model access.
    public static let defaultScopes = ["openid", "profile", "gated-repos", "read-repos"]

    public init(clientID: String, redirectURI: URL, scopes: [String] = HFOAuthConfiguration.defaultScopes,
                authorizationEndpoint: URL = URL(string: "https://huggingface.co/oauth/authorize")!,
                tokenEndpoint: URL = URL(string: "https://huggingface.co/oauth/token")!,
                userInfoEndpoint: URL = URL(string: "https://huggingface.co/oauth/userinfo")!) {
        self.clientID = clientID; self.redirectURI = redirectURI; self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint; self.tokenEndpoint = tokenEndpoint
        self.userInfoEndpoint = userInfoEndpoint
    }
}

/// PKCE pair. `verifier` never leaves esh (never sent to the consumer, never logged).
public struct HFOAuthPKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public init(verifier: String, challenge: String) { self.verifier = verifier; self.challenge = challenge }

    public static func generate() -> HFOAuthPKCE {
        let verifier = HFOAuthRandom.urlSafeToken(byteCount: 32)     // 43-char base64url, within RFC 7636 [43,128]
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return HFOAuthPKCE(verifier: verifier, challenge: challenge)
    }
}

public enum HFOAuthRandom {
    /// Cryptographically strong URL-safe token (base64url, no padding).
    public static func urlSafeToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        #if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        }
        #else
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        #endif
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Transient pending session held by the runtime between `begin` and `complete`. Contains the PKCE verifier
/// and state — never persisted to disk, never handed to the consumer.
public struct HFPendingOAuthSession: Sendable, Equatable {
    public let id: String
    public let state: String
    public let verifier: String
    public let configuration: HFOAuthConfiguration
    public let createdAt: Date
    public init(id: String, state: String, verifier: String, configuration: HFOAuthConfiguration, createdAt: Date = Date()) {
        self.id = id; self.state = state; self.verifier = verifier
        self.configuration = configuration; self.createdAt = createdAt
    }
    public func isExpired(asOf now: Date = Date(), ttl: TimeInterval = 600) -> Bool {
        now.timeIntervalSince(createdAt) > ttl
    }
}

/// The public result of `begin` — the consumer opens `authorizationURL` in a browser and later returns the
/// callback URL together with `id`.
public struct HFAuthorizationRequest: Sendable, Equatable {
    public let id: String
    public let authorizationURL: URL
    public init(id: String, authorizationURL: URL) { self.id = id; self.authorizationURL = authorizationURL }
}

public enum HFOAuthURLBuilder {
    /// Build the authorization URL with correct percent-encoding (never string concatenation).
    public static func authorizationURL(configuration: HFOAuthConfiguration, state: String, challenge: String) -> URL {
        var comps = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: configuration.clientID),
            .init(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            .init(name: "scope", value: configuration.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        return comps.url!
    }
}

/// Parsed OAuth callback. `error` (e.g. "access_denied") takes precedence over `code`.
public struct HFOAuthCallback: Sendable, Equatable {
    public let state: String?
    public let code: String?
    public let error: String?
    public let errorDescription: String?

    /// Parse + validate a callback URL against the configured redirect URI. Custom-scheme URIs require exact
    /// scheme + host + path; loopback `http` URIs (localhost/127.0.0.1/[::1]) match on host + path and ignore
    /// the port (RFC 8252 §7.3). Throws `oauthCallbackInvalid` when the URL does not belong to this redirect.
    public static func parse(_ url: URL, redirectURI: URL) throws -> HFOAuthCallback {
        guard matches(callback: url, redirect: redirectURI) else { throw HuggingFaceError.oauthCallbackInvalid }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value?.removingPercentEncoding ?? items.first { $0.name == name }?.value }
        return HFOAuthCallback(state: value("state"), code: value("code"),
                               error: value("error"), errorDescription: value("error_description"))
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        switch url.host?.lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]": return true
        default: return false
        }
    }
    static func matches(callback: URL, redirect: URL) -> Bool {
        let cs = callback.scheme?.lowercased(), rs = redirect.scheme?.lowercased()
        guard cs == rs else { return false }
        if isLoopback(redirect) {
            // Loopback: host + path must match; any port is accepted.
            return callback.host?.lowercased() == redirect.host?.lowercased()
                && normalize(callback.path) == normalize(redirect.path)
        }
        // Custom scheme / https: host + path must match exactly (port included).
        return callback.host?.lowercased() == redirect.host?.lowercased()
            && callback.port == redirect.port
            && normalize(callback.path) == normalize(redirect.path)
    }
    private static func normalize(_ path: String) -> String {
        let p = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return p.isEmpty ? "/" : p
    }
}

/// The raw HF token endpoint response.
struct HFOAuthTokenResponse: Decodable {
    let access_token: String
    let token_type: String?
    let expires_in: Double?
    let refresh_token: String?
    let scope: String?
    let id_token: String?
}

/// The userinfo/whoami identity shape.
public struct HFUserInfo: Decodable, Sendable, Equatable {
    public let name: String?
    public let preferredUsername: String?
    public let sub: String?
    private enum CodingKeys: String, CodingKey { case name, preferredUsername = "preferred_username", sub }
    public var username: String? { preferredUsername ?? name }
}

/// Performs the public-client token exchange + refresh over the injectable HTTP seam. No client secret.
public struct HFOAuthClient: Sendable {
    private let http: HFHTTPClient
    public init(http: HFHTTPClient) { self.http = http }

    /// Exchange an authorization code (+ PKCE verifier) for a credential.
    public func exchangeCode(_ code: String, session: HFPendingOAuthSession) async throws -> HFCredential {
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": session.configuration.clientID,
            "redirect_uri": session.configuration.redirectURI.absoluteString,
            "code_verifier": session.verifier,
        ]
        let resp = try await post(session.configuration.tokenEndpoint, form: form)
        guard resp.statusCode == 200 else { throw HuggingFaceError.oauthTokenExchangeFailed }
        return try credential(from: resp.data, clientID: session.configuration.clientID,
                              fallbackScopes: session.configuration.scopes)
    }

    /// Refresh an expired OAuth credential (only when a refresh token was issued).
    public func refresh(_ credential: HFCredential, tokenEndpoint: URL) async throws -> HFCredential {
        guard let refreshToken = credential.refreshToken, let clientID = credential.clientID else {
            throw HuggingFaceError.oauthReauthenticationRequired
        }
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        let resp = try await post(tokenEndpoint, form: form)
        guard resp.statusCode == 200 else { throw HuggingFaceError.oauthReauthenticationRequired }
        var refreshed = try self.credential(from: resp.data, clientID: clientID, fallbackScopes: credential.scopes ?? [])
        // HF may omit a new refresh token on refresh; keep the prior one so the session stays refreshable.
        if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
        return refreshed
    }

    // MARK: internals

    private func credential(from data: Data, clientID: String, fallbackScopes: [String]) throws -> HFCredential {
        guard let token = try? JSONDecoder().decode(HFOAuthTokenResponse.self, from: data) else {
            throw HuggingFaceError.oauthTokenExchangeFailed
        }
        let scopes = token.scope?.split(separator: " ").map(String.init)
        let expiresAt = token.expires_in.map { Date().addingTimeInterval($0) }
        return HFCredential(accessToken: token.access_token, method: .oauth, expiresAt: expiresAt,
                            scopes: scopes ?? (fallbackScopes.isEmpty ? nil : fallbackScopes),
                            refreshToken: token.refresh_token, tokenType: token.token_type, clientID: clientID)
    }

    private func post(_ url: URL, form: [String: String]) async throws -> HFHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(encodeForm(form).utf8)
        return try await http.send(request)
    }
    private func encodeForm(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")   // RFC 3986 unreserved; everything else percent-encoded
        return form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}
