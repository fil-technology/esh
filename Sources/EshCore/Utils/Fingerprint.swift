import CryptoKit
import Foundation

public enum Fingerprint {
    public static func sha256(_ values: some Sequence<String>) -> String {
        let input = values.joined(separator: "|")
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
