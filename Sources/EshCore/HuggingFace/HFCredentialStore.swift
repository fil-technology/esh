import Foundation
#if canImport(Security)
import Security
#endif

// Secure credential storage (HF3 → rc.24). The credential lives ONLY here (Keychain). The public API exposes
// account state, never the raw token; nothing writes it to UserDefaults/SwiftData/JSON-on-disk/logs/
// provenance. One store serves both PAT and OAuth; `loadToken()` returns whichever access token is current,
// so every existing bearer injection point is unified with zero forking by auth method.

public protocol HFCredentialStore: Sendable {
    /// The full current credential (PAT or OAuth), or nil when disconnected.
    func loadCredential() -> HFCredential?
    /// Atomically replace the stored credential.
    func saveCredential(_ credential: HFCredential) throws
    /// Clear the stored credential (sign out).
    func deleteToken()
}

public extension HFCredentialStore {
    /// The bearer access token for authenticated requests (nil when disconnected). Universal accessor used by
    /// every injection point — it does not distinguish PAT vs OAuth.
    func loadToken() -> String? { loadCredential()?.accessToken }
    /// Store a manually provided PAT (Advanced fallback). OAuth uses `saveCredential`.
    func saveToken(_ token: String) throws { try saveCredential(HFCredential(accessToken: token, method: .pat)) }
}

/// Redacts anything token-like from a string before it can reach a log line — PAT (`hf_…`), OAuth access
/// tokens (`hf_oauth_…`), Bearer headers, and JWT-shaped id/refresh tokens. Never depends on the `hf_` prefix
/// alone.
public enum HFTokenRedaction {
    private static let patterns: [String] = [
        "hf_[A-Za-z0-9_]+",                                             // hf_… and hf_oauth_…
        "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+",         // JWT (id_token / some refresh tokens)
    ]
    public static func redact(_ text: String) -> String {
        var out = text
        for pattern in patterns {
            if let re = try? NSRegularExpression(pattern: pattern) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "***")
            }
        }
        // Redact bearer values that don't match the shapes above (e.g. opaque refresh tokens).
        if let re = try? NSRegularExpression(pattern: "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+") {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "Bearer ***")
        }
        return out
    }
}

public enum HFCredentialError: Error, Equatable { case keychainFailure(OSStatus) }

/// macOS/iOS Keychain generic-password store. Stores the JSON-encoded `HFCredential`. A direct-distribution
/// macOS app runs sandbox-off, so no keychain-access-group entitlement is needed; a sandboxed/iOS build needs
/// the keychain entitlement. Reads tolerate a legacy rc.23 raw-token value and migrate it to a PAT credential.
public struct KeychainHFCredentialStore: HFCredentialStore {
    private let service: String
    private let account: String
    public init(service: String = "technology.fil.esh.huggingface", account: String = "hf-token") {
        self.service = service; self.account = account
    }

    #if canImport(Security)
    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private func loadData() -> Data? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return data
    }
    public func loadCredential() -> HFCredential? {
        guard let data = loadData() else { return nil }
        if let credential = try? JSONDecoder().decode(HFCredential.self, from: data) {
            return credential
        }
        // Legacy rc.23 value: the raw token string. Migrate to a PAT credential in memory (rewritten on next save).
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty, !raw.hasPrefix("{") {
            return HFCredential(accessToken: raw, method: .pat)
        }
        return nil
    }
    public func saveCredential(_ credential: HFCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw HFCredentialError.keychainFailure(addStatus) }
        } else if status != errSecSuccess {
            throw HFCredentialError.keychainFailure(status)
        }
    }
    public func deleteToken() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
    #else
    public func loadCredential() -> HFCredential? { nil }
    public func saveCredential(_ credential: HFCredential) throws {}
    public func deleteToken() {}
    #endif
}

/// In-memory store for tests (never touches the Keychain).
public final class InMemoryHFCredentialStore: HFCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: HFCredential?
    public init(credential: HFCredential? = nil) { self.credential = credential }
    /// Convenience for existing tests: seed a PAT token.
    public convenience init(token: String?) {
        self.init(credential: token.map { HFCredential(accessToken: $0, method: .pat) })
    }
    public func loadCredential() -> HFCredential? { lock.lock(); defer { lock.unlock() }; return credential }
    public func saveCredential(_ credential: HFCredential) throws { lock.lock(); self.credential = credential; lock.unlock() }
    public func deleteToken() { lock.lock(); credential = nil; lock.unlock() }
}
