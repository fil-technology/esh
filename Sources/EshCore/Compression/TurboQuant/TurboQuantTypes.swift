import Foundation

public struct TurboQuantConfiguration: Codable, Hashable, Sendable {
    public var pythonExecutablePath: String?
    public var helperScriptPath: String?
    public var bits: Double
    public var seed: Int
    public var mlxVLMVersion: String

    public init(
        pythonExecutablePath: String? = nil,
        helperScriptPath: String? = nil,
        bits: Double = 3.5,
        seed: Int = 0,
        mlxVLMVersion: String = "0.5.0"
    ) {
        self.pythonExecutablePath = pythonExecutablePath
        self.helperScriptPath = helperScriptPath
        self.bits = bits
        self.seed = seed
        self.mlxVLMVersion = mlxVLMVersion
    }
}
