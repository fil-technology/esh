import Foundation

public enum StoreError: Error, LocalizedError {
    case notFound(String)
    case invalidManifest(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(message), let .invalidManifest(message):
            return message
        }
    }
}
