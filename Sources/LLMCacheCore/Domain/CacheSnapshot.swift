import Foundation

public struct CacheSnapshot: Codable, Hashable, Sendable {
    public var format: String
    public var metadata: [String: String]
    public var tensors: [CacheTensor]

    public init(format: String, metadata: [String: String] = [:], tensors: [CacheTensor]) {
        self.format = format
        self.metadata = metadata
        self.tensors = tensors
    }
}
