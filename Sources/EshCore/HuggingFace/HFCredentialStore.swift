import Foundation
#if canImport(Security)
import Security
#endif

// Secure token storage (HF3). The token lives ONLY here (Keychain). The public API exposes account state,
// never the raw token; nothing writes it to UserDefaults/SwiftData/JSON/logs/provenance.

public protocol HFCredentialStore: Sendable {
    func loadToken() -> String?
    func saveToken(_ token: String) throws
    func deleteToken()
}

/// Redacts anything token-like from a string before it can reach a log line.
public enum HFTokenRedaction {
    public static func redact(_ text: String) -> String {
        // HF tokens look like hf_XXXX…; replace any hf_ + word chars with hf_***.
        guard let re = try? NSRegularExpression(pattern: "hf_[A-Za-z0-9]+") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "hf_***")
    }
}

public enum HFCredentialError: Error, Equatable { case keychainFailure(OSStatus) }

/// macOS/iOS Keychain generic-password store. Direct-distribution macOS app runs sandbox-off, so no
/// keychain-access-group entitlement is needed; a sandboxed/iOS build needs the keychain entitlement.
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
    public func loadToken() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }
    public func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        // Try update first, then add.
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
    public func loadToken() -> String? { nil }
    public func saveToken(_ token: String) throws {}
    public func deleteToken() {}
    #endif
}

/// In-memory store for tests (never touches the Keychain).
public final class InMemoryHFCredentialStore: HFCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func loadToken() -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func saveToken(_ token: String) throws { lock.lock(); self.token = token; lock.unlock() }
    public func deleteToken() { lock.lock(); token = nil; lock.unlock() }
}
