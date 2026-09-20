import Foundation

// The single credential model shared by manual PAT and OAuth (rc.24). One credential path feeds every
// authenticated HF request (Authorization header, HubApi, search, resolve, download). The raw secret lives
// ONLY in the Keychain; nothing here is ever logged, put in provenance, or exposed by the public surface.

public enum HFAuthMethod: String, Codable, Sendable, Equatable {
    case pat        // manually created / pasted access token (rc.23 path, Advanced fallback)
    case oauth      // Authorization Code + PKCE (rc.24 primary path)
}

/// A stored Hugging Face credential. `accessToken` is the bearer used everywhere; the rest is normalized
/// metadata (present for OAuth, mostly nil for PAT). `clientID` is retained for OAuth so a refresh is
/// self-contained; it is public app configuration, not a secret.
public struct HFCredential: Codable, Sendable, Equatable {
    public var accessToken: String
    public var method: HFAuthMethod
    public var expiresAt: Date?
    public var scopes: [String]?
    public var refreshToken: String?
    public var tokenType: String?
    public var clientID: String?

    public init(accessToken: String, method: HFAuthMethod, expiresAt: Date? = nil,
                scopes: [String]? = nil, refreshToken: String? = nil, tokenType: String? = nil,
                clientID: String? = nil) {
        self.accessToken = accessToken; self.method = method; self.expiresAt = expiresAt
        self.scopes = scopes; self.refreshToken = refreshToken; self.tokenType = tokenType
        self.clientID = clientID
    }

    /// True when the credential has an expiry that has passed (with a small leeway so we refresh a bit early).
    public func isExpired(asOf now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }   // PAT / no-expiry credentials never expire locally
        return expiresAt.addingTimeInterval(-leeway) <= now
    }

    public var canRefresh: Bool { (refreshToken?.isEmpty == false) && (clientID?.isEmpty == false) }
}
