import Foundation

public struct CacheTensor: Codable, Hashable, Sendable {
    public var name: String
    public var shape: [Int]
    public var dtype: String
    public var data: Data

    public init(name: String, shape: [Int], dtype: String, data: Data) {
        self.name = name
        self.shape = shape
        self.dtype = dtype
        self.data = data
    }
}
